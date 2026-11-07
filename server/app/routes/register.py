from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import invite_limiter, new_token, sha256
from ..db import get_session
from ..models import Device, Invite, OneTimePreKey, User, now
from ..schemas import RegisterIn, RegisterOut, unb64

router = APIRouter(tags=["register"])


@router.post("/register", response_model=RegisterOut, status_code=201, dependencies=[Depends(invite_limiter)])
async def register(body: RegisterIn, session: Annotated[AsyncSession, Depends(get_session)]) -> RegisterOut:
    """Unico ingresso nell'app. Il riscatto e' atomico: la riga invito viene
    aggiornata con una condizione sullo stato, quindi due richieste parallele
    con lo stesso token non possono creare due account."""
    inv = await session.scalar(select(Invite).where(Invite.token_hash == sha256(body.invite_token)))
    if inv is None or inv.status != "active":
        raise HTTPException(403, "invito non valido, scaduto, revocato o gia' usato")

    if await session.scalar(select(User.id).where(User.username == body.username)):
        raise HTTPException(409, "nome utente gia' in uso")

    user = User(
        username=body.username,
        identity_key=unb64(body.identity_key),
        registration_id=body.registration_id,
    )
    session.add(user)
    await session.flush()

    token = new_token()
    dev = Device(
        user_id=user.id,
        device_id=1,
        name=body.device_name,
        token_hash=sha256(token),
        apns_token=body.apns_token,
        signed_prekey_id=body.signed_prekey_id,
        signed_prekey=unb64(body.signed_prekey),
        signed_prekey_signature=unb64(body.signed_prekey_signature),
        kyber_prekey_id=body.kyber_prekey_id,
        kyber_prekey=unb64(body.kyber_prekey) if body.kyber_prekey else None,
        kyber_prekey_signature=unb64(body.kyber_prekey_signature) if body.kyber_prekey_signature else None,
    )
    session.add(dev)
    await session.flush()
    for pk in body.one_time_prekeys:
        session.add(OneTimePreKey(device_pk=dev.id, key_id=pk.key_id, public_key=unb64(pk.public_key)))

    # riscatto condizionale: vince una sola transazione
    from sqlalchemy import update

    res = await session.execute(
        update(Invite)
        .where(Invite.id == inv.id, Invite.redeemed_at.is_(None), Invite.revoked_at.is_(None))
        .values(redeemed_at=now(), redeemed_by=user.id)
    )
    if res.rowcount != 1:
        await session.rollback()
        raise HTTPException(409, "invito appena consumato da un'altra richiesta")

    await session.commit()
    return RegisterOut(user_id=user.id, username=user.username, device_id=1, token=token)
