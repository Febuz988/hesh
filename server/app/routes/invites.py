from datetime import timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import current_device, new_token, sha256
from ..config import settings
from ..db import get_session
from ..models import Device, Invite, now
from ..schemas import InviteCreateIn, InviteOut

router = APIRouter(prefix="/invites", tags=["invites"])

Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]


def _out(inv: Invite, token: str | None = None) -> InviteOut:
    return InviteOut(
        id=inv.id,
        label=inv.label,
        status=inv.status,
        created_at=inv.created_at.isoformat(),
        expires_at=inv.expires_at.isoformat(),
        token=token,
        link=f"hesh://invite/{token}" if token else None,
    )


@router.post("", response_model=InviteOut, status_code=201)
async def create_invite(body: InviteCreateIn, dev: Dev, session: Sess) -> InviteOut:
    """Qualsiasi membro puo' invitare. Il token viene mostrato una volta sola;
    il server ne conserva solo l'hash."""
    token = new_token()
    inv = Invite(
        token_hash=sha256(token),
        issuer_id=dev.user_id,
        label=body.label,
        expires_at=now() + timedelta(hours=settings.invite_ttl_hours),
    )
    session.add(inv)
    await session.commit()
    return _out(inv, token)


@router.get("", response_model=list[InviteOut])
async def list_invites(dev: Dev, session: Sess) -> list[InviteOut]:
    rows = await session.scalars(
        select(Invite).where(Invite.issuer_id == dev.user_id).order_by(Invite.created_at.desc())
    )
    return [_out(i) for i in rows]


@router.delete("/{invite_id}", status_code=204)
async def revoke_invite(invite_id: str, dev: Dev, session: Sess) -> None:
    inv = await session.get(Invite, invite_id)
    if inv is None or inv.issuer_id != dev.user_id:
        raise HTTPException(404, "invito non trovato")
    if inv.redeemed_at is not None:
        raise HTTPException(409, "invito gia' usato")
    inv.revoked_at = now()
    await session.commit()
