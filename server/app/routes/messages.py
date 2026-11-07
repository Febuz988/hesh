from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import current_device, device_from_token
from ..db import SessionLocal, get_session
from ..models import Device, Envelope, User
from ..push import notify
from ..schemas import AckIn, EnvelopeBatchIn, EnvelopeOut, b64, unb64
from ..ws import hub

router = APIRouter(prefix="/messages", tags=["messages"])
Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]


def _out(env: Envelope, from_username: str) -> EnvelopeOut:
    return EnvelopeOut(
        id=env.id,
        from_username=from_username,
        from_device_id=env.from_device_id,
        msg_type=env.msg_type,
        ciphertext=b64(env.ciphertext),
        priority=env.priority,
        created_at=env.created_at.isoformat(),
    )


@router.post("", status_code=202)
async def send(body: EnvelopeBatchIn, dev: Dev, session: Sess) -> dict:
    """Un batch = un messaggio logico inviato a N dispositivi (gruppi: fan-out
    lato client con Sender Keys). Il server accoda e spinge."""
    sender = await session.get(User, dev.user_id)
    assert sender is not None
    queued: list[tuple[Envelope, Device]] = []
    for e in body.envelopes:
        target_user = await session.scalar(select(User).where(User.username == e.to_username.lower(), User.disabled_at.is_(None)))
        if target_user is None:
            raise HTTPException(404, f"destinatario {e.to_username} non trovato")
        target = await session.scalar(
            select(Device).where(Device.user_id == target_user.id, Device.device_id == e.to_device_id, Device.revoked_at.is_(None))
        )
        if target is None:
            raise HTTPException(404, f"dispositivo {e.to_username}/{e.to_device_id} non trovato")
        env = Envelope(
            to_device=target.id,
            from_user=sender.id,
            from_device_id=dev.device_id,
            msg_type=e.msg_type,
            ciphertext=unb64(e.ciphertext),
            priority=e.priority,
        )
        session.add(env)
        queued.append((env, target))
    await session.commit()

    delivered_live = 0
    for env, target in queued:
        live = await hub.push(target.id, {"type": "envelope", "envelope": _out(env, sender.username).model_dump()})
        if live:
            delivered_live += 1
        else:
            await notify(target.apns_token, env.priority)
    return {"queued": len(queued), "pushed_live": delivered_live}


@router.get("", response_model=list[EnvelopeOut])
async def fetch(dev: Dev, session: Sess, limit: int = 100) -> list[EnvelopeOut]:
    rows = await session.scalars(
        select(Envelope).where(Envelope.to_device == dev.id).order_by(Envelope.created_at).limit(min(limit, 500))
    )
    out = []
    for env in rows:
        u = await session.get(User, env.from_user)
        out.append(_out(env, u.username if u else "?"))
    return out


@router.post("/ack", status_code=204)
async def ack(body: AckIn, dev: Dev, session: Sess) -> None:
    """Il client conferma la ricezione: la busta sparisce dal server."""
    await session.execute(delete(Envelope).where(Envelope.to_device == dev.id, Envelope.id.in_(body.ids)))
    await session.commit()


@router.websocket("/stream")
async def stream(ws: WebSocket, token: str) -> None:
    async with SessionLocal() as session:
        dev = await device_from_token(session, token)
    if dev is None:
        await ws.close(code=4401)
        return
    await ws.accept()
    await hub.connect(dev.id, ws)
    try:
        # svuota la coda alla connessione
        async with SessionLocal() as session:
            rows = await session.scalars(select(Envelope).where(Envelope.to_device == dev.id).order_by(Envelope.created_at))
            for env in rows:
                u = await session.get(User, env.from_user)
                await ws.send_json({"type": "envelope", "envelope": _out(env, u.username if u else "?").model_dump()})
        while True:
            msg = await ws.receive_json()
            if msg.get("type") == "ack" and isinstance(msg.get("ids"), list):
                async with SessionLocal() as session:
                    await session.execute(delete(Envelope).where(Envelope.to_device == dev.id, Envelope.id.in_(msg["ids"][:500])))
                    await session.commit()
            elif msg.get("type") == "ping":
                await ws.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.disconnect(dev.id, ws)
