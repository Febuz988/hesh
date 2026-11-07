import hashlib
import secrets
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import Device, User, now

bearer = HTTPBearer(auto_error=False)


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def new_token() -> str:
    return secrets.token_urlsafe(32)


PROVISIONING_PATHS = ("/auth/backup", "/auth/reprovision", "/devices/me/logout")


async def current_device(
    request: Request,
    creds: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Device:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "token mancante")
    dev = await session.scalar(select(Device).where(Device.token_hash == sha256(creds.credentials)))
    if dev is None or dev.revoked_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "sessione non valida")
    if dev.device_id == 0 and not request.url.path.startswith(PROVISIONING_PATHS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "dispositivo in provisioning: completa il ripristino")
    user = await session.get(User, dev.user_id)
    if user is None or user.disabled_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "account disattivato")
    dev.last_seen_at = now()
    await session.commit()
    return dev


async def device_from_token(session: AsyncSession, token: str) -> Device | None:
    """Per il WebSocket, dove non c'e' l'header Authorization standard."""
    dev = await session.scalar(select(Device).where(Device.token_hash == sha256(token)))
    if dev is None or dev.revoked_at is not None:
        return None
    return dev


class RateLimiter:
    """Limite semplice in memoria per IP: sufficiente per un server di famiglia.
    In produzione dietro Nginx usare anche limit_req."""

    def __init__(self, max_hits: int, window_s: int) -> None:
        self.max_hits, self.window_s = max_hits, window_s
        self._hits: dict[str, list[float]] = {}

    async def __call__(self, request: Request) -> None:
        import time

        ip = request.client.host if request.client else "?"
        t = time.monotonic()
        hits = [h for h in self._hits.get(ip, []) if t - h < self.window_s]
        if len(hits) >= self.max_hits:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "troppi tentativi")
        hits.append(t)
        self._hits[ip] = hits


invite_limiter = RateLimiter(max_hits=10, window_s=600)
