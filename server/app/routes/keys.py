from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import current_device
from ..config import settings
from ..db import get_session
from ..models import Device, OneTimePreKey, User
from ..schemas import PreKeyBundleOut, ReplenishIn, UserLookupOut, b64, unb64

router = APIRouter(prefix="/keys", tags=["keys"])
Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]


@router.get("/lookup/{username}", response_model=UserLookupOut)
async def lookup(username: str, _: Dev, session: Sess) -> UserLookupOut:
    """Serve per le richieste di contatto tra membri ammessi. Richiede sessione:
    nessuna enumerazione dall'esterno."""
    user = await session.scalar(select(User).where(User.username == username.lower(), User.disabled_at.is_(None)))
    if user is None:
        raise HTTPException(404, "utente non trovato")
    devs = await session.scalars(select(Device.device_id).where(Device.user_id == user.id, Device.revoked_at.is_(None)))
    return UserLookupOut(user_id=user.id, username=user.username, identity_key=b64(user.identity_key), devices=list(devs))


@router.get("/bundle/{username}/{device_id}", response_model=PreKeyBundleOut)
async def bundle(username: str, device_id: int, _: Dev, session: Sess) -> PreKeyBundleOut:
    """Consegna un prekey bundle e consuma una one-time prekey (cancellazione
    atomica della riga scelta)."""
    user = await session.scalar(select(User).where(User.username == username.lower(), User.disabled_at.is_(None)))
    if user is None:
        raise HTTPException(404, "utente non trovato")
    dev = await session.scalar(
        select(Device).where(Device.user_id == user.id, Device.device_id == device_id, Device.revoked_at.is_(None))
    )
    if dev is None:
        raise HTTPException(404, "dispositivo non trovato")

    otp = await session.scalar(
        select(OneTimePreKey).where(OneTimePreKey.device_pk == dev.id).order_by(OneTimePreKey.id).limit(1)
    )
    otp_id, otp_key = None, None
    if otp is not None:
        res = await session.execute(delete(OneTimePreKey).where(OneTimePreKey.id == otp.id))
        if res.rowcount == 1:
            otp_id, otp_key = otp.key_id, b64(otp.public_key)
    await session.commit()

    return PreKeyBundleOut(
        user_id=user.id,
        username=user.username,
        device_id=dev.device_id,
        registration_id=user.registration_id,
        identity_key=b64(user.identity_key),
        signed_prekey_id=dev.signed_prekey_id,
        signed_prekey=b64(dev.signed_prekey),
        signed_prekey_signature=b64(dev.signed_prekey_signature),
        kyber_prekey_id=dev.kyber_prekey_id,
        kyber_prekey=b64(dev.kyber_prekey) if dev.kyber_prekey else None,
        kyber_prekey_signature=b64(dev.kyber_prekey_signature) if dev.kyber_prekey_signature else None,
        one_time_prekey_id=otp_id,
        one_time_prekey=otp_key,
    )


@router.get("/count")
async def count(dev: Dev, session: Sess) -> dict:
    n = await session.scalar(select(func.count()).select_from(OneTimePreKey).where(OneTimePreKey.device_pk == dev.id))
    return {"one_time_prekeys": n or 0, "low": (n or 0) < settings.one_time_prekey_low_watermark}


@router.put("/replenish", status_code=204)
async def replenish(body: ReplenishIn, dev: Dev, session: Sess) -> None:
    if body.signed_prekey and body.signed_prekey_signature and body.signed_prekey_id is not None:
        dev.signed_prekey_id = body.signed_prekey_id
        dev.signed_prekey = unb64(body.signed_prekey)
        dev.signed_prekey_signature = unb64(body.signed_prekey_signature)
    if body.kyber_prekey and body.kyber_prekey_signature and body.kyber_prekey_id is not None:
        dev.kyber_prekey_id = body.kyber_prekey_id
        dev.kyber_prekey = unb64(body.kyber_prekey)
        dev.kyber_prekey_signature = unb64(body.kyber_prekey_signature)
    for pk in body.one_time_prekeys:
        session.add(OneTimePreKey(device_pk=dev.id, key_id=pk.key_id, public_key=unb64(pk.public_key)))
    await session.commit()
