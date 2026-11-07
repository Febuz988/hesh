"""Blob opachi: il client cifra (AES-256-GCM, chiave dentro il messaggio) prima
di caricare. Il server conosce solo proprietario, dimensione e scadenza."""
import secrets
from datetime import timedelta
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import current_device
from ..config import settings
from ..db import get_session
from ..models import Attachment, Device, aware, now

router = APIRouter(prefix="/attachments", tags=["attachments"])
Sess = Annotated[AsyncSession, Depends(get_session)]
Dev = Annotated[Device, Depends(current_device)]


def _dir() -> Path:
    d = Path(settings.attachment_dir)
    d.mkdir(parents=True, exist_ok=True)
    return d


@router.post("", status_code=201)
async def upload(request: Request, dev: Dev, session: Sess) -> dict:
    """Body = bytes cifrati grezzi (Content-Type: application/octet-stream)."""
    max_bytes = settings.attachment_max_mb * 1024 * 1024
    name = secrets.token_hex(16)
    path = _dir() / name
    size = 0
    with path.open("wb") as f:
        async for chunk in request.stream():
            size += len(chunk)
            if size > max_bytes:
                f.close()
                path.unlink(missing_ok=True)
                raise HTTPException(413, "allegato troppo grande")
            f.write(chunk)
    if size == 0:
        path.unlink(missing_ok=True)
        raise HTTPException(400, "allegato vuoto")
    att = Attachment(owner_id=dev.user_id, size=size, path=str(path), expires_at=now() + timedelta(days=settings.queue_ttl_days))
    session.add(att)
    await session.commit()
    return {"id": att.id, "size": size, "expires_at": att.expires_at.isoformat()}


@router.get("/{attachment_id}")
async def download(attachment_id: str, _: Dev, session: Sess) -> FileResponse:
    """Chi ha l'id lo ha ricevuto dentro un messaggio cifrato; senza la chiave il
    blob e' inutile. Serve comunque una sessione valida."""
    att = await session.get(Attachment, attachment_id)
    if att is None or aware(att.expires_at) < now():
        raise HTTPException(404, "allegato non trovato")
    return FileResponse(att.path, media_type="application/octet-stream")


@router.delete("/{attachment_id}", status_code=204)
async def delete_attachment(attachment_id: str, dev: Dev, session: Sess) -> None:
    att = await session.get(Attachment, attachment_id)
    if att is None or att.owner_id != dev.user_id:
        raise HTTPException(404, "allegato non trovato")
    Path(att.path).unlink(missing_ok=True)
    await session.delete(att)
    await session.commit()
