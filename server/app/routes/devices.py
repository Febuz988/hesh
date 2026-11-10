from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import current_device
from ..db import get_session
from ..models import Device, User, now
from ..schemas import ApnsIn, DeviceOut, VoipIn

router = APIRouter(prefix="/devices", tags=["devices"])
Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]


@router.get("", response_model=list[DeviceOut])
async def list_devices(dev: Dev, session: Sess) -> list[DeviceOut]:
    rows = await session.scalars(select(Device).where(Device.user_id == dev.user_id, Device.revoked_at.is_(None)))
    return [
        DeviceOut(id=d.id, device_id=d.device_id, name=d.name, created_at=d.created_at.isoformat(),
                  last_seen_at=d.last_seen_at.isoformat(), current=d.id == dev.id)
        for d in rows
    ]


@router.put("/me/apns", status_code=204)
async def set_apns(body: ApnsIn, dev: Dev, session: Sess) -> None:
    dev.apns_token = body.apns_token
    await session.commit()


@router.put("/me/voip", status_code=204)
async def set_voip(body: VoipIn, dev: Dev, session: Sess) -> None:
    dev.voip_token = body.voip_token
    await session.commit()


@router.delete("/{device_pk}", status_code=204)
async def revoke(device_pk: str, dev: Dev, session: Sess) -> None:
    target = await session.get(Device, device_pk)
    if target is None or target.user_id != dev.user_id:
        raise HTTPException(404, "dispositivo non trovato")
    target.revoked_at = now()
    await session.commit()


@router.post("/me/logout", status_code=204)
async def logout(dev: Dev, session: Sess) -> None:
    dev.revoked_at = now()
    await session.commit()


@router.delete("/me/account", status_code=204)
async def delete_account(dev: Dev, session: Sess) -> None:
    """Disattiva l'account e revoca tutto. La cancellazione fisica dei residui
    e' compito del job di pulizia (entro 30 giorni)."""
    user = await session.get(User, dev.user_id)
    assert user is not None
    user.disabled_at = now()
    for d in await session.scalars(select(Device).where(Device.user_id == user.id)):
        d.revoked_at = now()
    await session.commit()
