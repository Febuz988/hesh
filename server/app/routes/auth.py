"""Passkey (WebAuthn) e backup cifrato.

Passkey: autentica l'account verso il server e produce una nuova sessione.
Backup: blob opaco cifrato dal client con la chiave derivata dalle 12 parole.
Riprovisioning: dopo il login con passkey e il ripristino del backup, il nuovo
dispositivo sostituisce il vecchio (stessa identity key, nuove prekey)."""
import json
from datetime import timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from ..auth import current_device, invite_limiter, new_token, sha256
from ..config import settings
from ..db import get_session
from ..models import AuthChallenge, Backup, Device, OneTimePreKey, Passkey, User, aware, now
from ..schemas import PreKeyIn, unb64

router = APIRouter(prefix="/auth", tags=["auth"])
Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]

ORIGINS = [f"https://{settings.rp_id}"]


async def _take_challenge(session: AsyncSession, challenge_id: str, kind: str) -> AuthChallenge:
    ch = await session.get(AuthChallenge, challenge_id)
    if ch is None or ch.kind != kind or aware(ch.created_at) < now() - timedelta(minutes=5):
        raise HTTPException(400, "challenge non valida o scaduta")
    await session.delete(ch)
    return ch


# ---------- registrazione passkey (utente gia' autenticato) ----------

@router.post("/passkey/register/options")
async def passkey_register_options(dev: Dev, session: Sess) -> dict:
    user = await session.get(User, dev.user_id)
    assert user is not None
    existing = await session.scalars(select(Passkey.credential_id).where(Passkey.user_id == user.id))
    opts = generate_registration_options(
        rp_id=settings.rp_id,
        rp_name=settings.rp_name,
        user_id=user.id.encode(),
        user_name=user.username,
        user_display_name=f"@{user.username}",
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
        exclude_credentials=[PublicKeyCredentialDescriptor(id=c) for c in existing],
    )
    ch = AuthChallenge(challenge=opts.challenge, user_id=user.id, kind="register")
    session.add(ch)
    await session.commit()
    return {"challenge_id": ch.id, "options": json.loads(options_to_json(opts))}


class PasskeyRegisterIn(BaseModel):
    challenge_id: str
    credential: dict
    name: str = Field(default="Passkey", max_length=64)


@router.post("/passkey/register", status_code=201)
async def passkey_register(body: PasskeyRegisterIn, dev: Dev, session: Sess) -> dict:
    ch = await _take_challenge(session, body.challenge_id, "register")
    if ch.user_id != dev.user_id:
        raise HTTPException(400, "challenge di un altro utente")
    try:
        v = verify_registration_response(
            credential=body.credential,
            expected_challenge=ch.challenge,
            expected_rp_id=settings.rp_id,
            expected_origin=ORIGINS,
            require_user_verification=True,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(400, f"passkey non valida: {exc}") from exc
    pk = Passkey(user_id=dev.user_id, credential_id=v.credential_id, public_key=v.credential_public_key, sign_count=v.sign_count, name=body.name)
    session.add(pk)
    await session.commit()
    return {"id": pk.id}


@router.get("/passkeys")
async def list_passkeys(dev: Dev, session: Sess) -> list[dict]:
    rows = await session.scalars(select(Passkey).where(Passkey.user_id == dev.user_id))
    return [{"id": p.id, "name": p.name, "created_at": p.created_at.isoformat()} for p in rows]


@router.delete("/passkeys/{passkey_id}", status_code=204)
async def delete_passkey(passkey_id: str, dev: Dev, session: Sess) -> None:
    await session.execute(delete(Passkey).where(Passkey.id == passkey_id, Passkey.user_id == dev.user_id))
    await session.commit()


# ---------- login con passkey (nuovo dispositivo) ----------

class LoginOptionsIn(BaseModel):
    username: str = Field(min_length=3, max_length=20)


@router.post("/passkey/login/options", dependencies=[Depends(invite_limiter)])
async def passkey_login_options(body: LoginOptionsIn, session: Sess) -> dict:
    user = await session.scalar(select(User).where(User.username == body.username.lower(), User.disabled_at.is_(None)))
    creds = []
    if user is not None:
        creds = [PublicKeyCredentialDescriptor(id=c) for c in await session.scalars(select(Passkey.credential_id).where(Passkey.user_id == user.id))]
    # Anche per un utente inesistente rispondiamo con opzioni valide: niente enumerazione.
    opts = generate_authentication_options(rp_id=settings.rp_id, allow_credentials=creds, user_verification=UserVerificationRequirement.REQUIRED)
    ch = AuthChallenge(challenge=opts.challenge, user_id=user.id if user else None, kind="login")
    session.add(ch)
    await session.commit()
    return {"challenge_id": ch.id, "options": json.loads(options_to_json(opts))}


class PasskeyLoginIn(BaseModel):
    challenge_id: str
    credential: dict
    device_name: str = Field(default="iPhone", max_length=64)


@router.post("/passkey/login", dependencies=[Depends(invite_limiter)])
async def passkey_login(body: PasskeyLoginIn, session: Sess) -> dict:
    """Verifica l'assertion e apre una sessione 'provisioning': il dispositivo puo'
    solo scaricare il backup e completare il riprovisioning delle chiavi."""
    ch = await _take_challenge(session, body.challenge_id, "login")
    if ch.user_id is None:
        raise HTTPException(403, "passkey non riconosciuta")
    raw_id = body.credential.get("rawId") or body.credential.get("id")
    from webauthn.helpers import base64url_to_bytes

    try:
        cred_id = base64url_to_bytes(raw_id)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(400, "credential malformata") from exc
    pk = await session.scalar(select(Passkey).where(Passkey.credential_id == cred_id, Passkey.user_id == ch.user_id))
    if pk is None:
        raise HTTPException(403, "passkey non riconosciuta")
    try:
        v = verify_authentication_response(
            credential=body.credential,
            expected_challenge=ch.challenge,
            expected_rp_id=settings.rp_id,
            expected_origin=ORIGINS,
            credential_public_key=pk.public_key,
            credential_current_sign_count=pk.sign_count,
            require_user_verification=True,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(403, f"verifica fallita: {exc}") from exc
    pk.sign_count = v.new_sign_count

    user = await session.get(User, ch.user_id)
    assert user is not None
    # Nuovo dispositivo in stato provisioning: nessuna prekey finche' non ripristina le chiavi.
    token = new_token()
    dev = Device(
        user_id=user.id, device_id=0, name=body.device_name, token_hash=sha256(token),
        signed_prekey_id=0, signed_prekey=b"", signed_prekey_signature=b"",
    )
    session.add(dev)
    await session.commit()
    return {"user_id": user.id, "username": user.username, "token": token, "provisioning": True}


# ---------- backup ----------

@router.put("/backup", status_code=204)
async def put_backup(request: Request, dev: Dev, session: Sess) -> None:
    blob = await request.body()
    if len(blob) > settings.backup_max_mb * 1024 * 1024:
        raise HTTPException(413, "backup troppo grande")
    b = await session.get(Backup, dev.user_id)
    if b is None:
        session.add(Backup(user_id=dev.user_id, blob=blob))
    else:
        b.blob = blob
        b.version += 1
        b.updated_at = now()
    await session.commit()


@router.get("/backup/meta")
async def backup_meta(dev: Dev, session: Sess) -> dict:
    """Solo versione e data: per mostrare 'ultimo backup' senza scaricare il blob."""
    b = await session.get(Backup, dev.user_id)
    if b is None:
        raise HTTPException(404, "nessun backup")
    return {"version": b.version, "updated_at": int(aware(b.updated_at).timestamp()), "bytes": len(b.blob)}


@router.get("/backup")
async def get_backup(dev: Dev, session: Sess):
    from fastapi.responses import Response

    b = await session.get(Backup, dev.user_id)
    if b is None:
        raise HTTPException(404, "nessun backup")
    return Response(content=b.blob, media_type="application/octet-stream", headers={"X-Backup-Version": str(b.version)})


# ---------- riprovisioning dopo il ripristino ----------

class ReprovisionIn(BaseModel):
    identity_key: str
    registration_id: int
    signed_prekey_id: int
    signed_prekey: str
    signed_prekey_signature: str
    kyber_prekey_id: int
    kyber_prekey: str
    kyber_prekey_signature: str
    one_time_prekeys: list[PreKeyIn] = Field(default_factory=list, max_length=200)
    apns_token: str | None = None


@router.post("/reprovision", status_code=204)
async def reprovision(body: ReprovisionIn, dev: Dev, session: Sess) -> None:
    """Il dispositivo in provisioning diventa il dispositivo 1; i vecchi vengono revocati.
    L'identity key deve coincidere con quella registrata: il ripristino non puo'
    cambiare identita'."""
    user = await session.get(User, dev.user_id)
    assert user is not None
    if dev.device_id != 0:
        raise HTTPException(409, "dispositivo gia' attivo")
    if unb64(body.identity_key) != user.identity_key:
        raise HTTPException(409, "identity key diversa da quella registrata: backup di un altro account?")
    user.registration_id = body.registration_id
    await session.execute(
        update(Device).where(Device.user_id == user.id, Device.id != dev.id, Device.revoked_at.is_(None)).values(revoked_at=now())
    )
    dev.device_id = 1
    dev.signed_prekey_id = body.signed_prekey_id
    dev.signed_prekey = unb64(body.signed_prekey)
    dev.signed_prekey_signature = unb64(body.signed_prekey_signature)
    dev.kyber_prekey_id = body.kyber_prekey_id
    dev.kyber_prekey = unb64(body.kyber_prekey)
    dev.kyber_prekey_signature = unb64(body.kyber_prekey_signature)
    dev.apns_token = body.apns_token
    await session.execute(delete(OneTimePreKey).where(OneTimePreKey.device_pk == dev.id))
    for pk in body.one_time_prekeys:
        session.add(OneTimePreKey(device_pk=dev.id, key_id=pk.key_id, public_key=unb64(pk.public_key)))
    await session.commit()
