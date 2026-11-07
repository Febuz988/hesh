"""Flusso completo milestone 1 senza crittografia reale: il server deve
comportarsi da postino cieco. Le chiavi sono byte casuali."""
import base64
import os
from datetime import timedelta

import pytest
from httpx import ASGITransport, AsyncClient

os.environ["HESH_DATABASE_URL"] = "sqlite+aiosqlite:///./test_hesh.db"
os.environ["HESH_ATTACHMENT_DIR"] = "./test_attachments"

from app.auth import new_token, sha256  # noqa: E402
from app.db import SessionLocal, engine, init_db  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base, Invite, User, now  # noqa: E402


def b(n: int = 32) -> str:
    return base64.b64encode(os.urandom(n)).decode()


def reg_body(invite: str, username: str) -> dict:
    return {
        "invite_token": invite,
        "username": username,
        "identity_key": b(33),
        "registration_id": 1234,
        "signed_prekey_id": 1,
        "signed_prekey": b(33),
        "signed_prekey_signature": b(64),
        "one_time_prekeys": [{"key_id": i, "public_key": b(33)} for i in range(5)],
    }


async def seed_invite() -> str:
    token = new_token()
    async with SessionLocal() as s:
        seed = User(username="__bootstrap__", identity_key=b"\x00", registration_id=1, is_admin=True)
        s.add(seed)
        await s.flush()
        s.add(Invite(token_hash=sha256(token), issuer_id=seed.id, expires_at=now() + timedelta(hours=1)))
        await s.commit()
    return token


@pytest.fixture
async def client():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c


async def test_invite_register_keys_messages(client: AsyncClient):
    token = await seed_invite()

    # nessun accesso senza invito
    r = await client.post("/register", json=reg_body("x" * 32, "nessuno"))
    assert r.status_code == 403

    r = await client.post("/register", json=reg_body(token, "fabio"))
    assert r.status_code == 201, r.text
    fabio = r.json()["token"]

    # invito monouso
    r = await client.post("/register", json=reg_body(token, "altro"))
    assert r.status_code == 403

    # fabio invita giulia
    r = await client.post("/invites", json={"label": "giulia"}, headers={"Authorization": f"Bearer {fabio}"})
    assert r.status_code == 201
    inv = r.json()
    assert inv["token"] and inv["status"] == "active"

    r = await client.post("/register", json=reg_body(inv["token"], "giulia"))
    assert r.status_code == 201
    giulia = r.json()["token"]

    # il token sparisce dall'elenco, lo stato diventa used
    r = await client.get("/invites", headers={"Authorization": f"Bearer {fabio}"})
    assert r.json()[0]["status"] == "used" and r.json()[0]["token"] is None

    # bundle: consuma una one-time prekey
    H = {"Authorization": f"Bearer {fabio}"}
    r = await client.get("/keys/bundle/giulia/1", headers=H)
    assert r.status_code == 200 and r.json()["one_time_prekey_id"] == 0
    r = await client.get("/keys/count", headers={"Authorization": f"Bearer {giulia}"})
    assert r.json()["one_time_prekeys"] == 4 and r.json()["low"] is True

    # lookup richiede sessione
    assert (await client.get("/keys/lookup/giulia")).status_code == 401

    # invio busta, ritiro, ack
    r = await client.post("/messages", json={"envelopes": [
        {"to_username": "giulia", "msg_type": 3, "ciphertext": b(200), "priority": "high"}]}, headers=H)
    assert r.status_code == 202 and r.json()["queued"] == 1
    G = {"Authorization": f"Bearer {giulia}"}
    r = await client.get("/messages", headers=G)
    assert len(r.json()) == 1 and r.json()[0]["from_username"] == "fabio" and r.json()[0]["priority"] == "high"
    env_id = r.json()[0]["id"]
    r = await client.post("/messages/ack", json={"ids": [env_id]}, headers=G)
    assert r.status_code == 204
    assert (await client.get("/messages", headers=G)).json() == []

    # allegato opaco
    blob = os.urandom(1024)
    r = await client.post("/attachments", content=blob, headers={**H, "Content-Type": "application/octet-stream"})
    assert r.status_code == 201
    att_id = r.json()["id"]
    r = await client.get(f"/attachments/{att_id}", headers=G)
    assert r.status_code == 200 and r.content == blob

    # logout revoca la sessione
    assert (await client.post("/devices/me/logout", headers=G)).status_code == 204
    assert (await client.get("/messages", headers=G)).status_code == 401
