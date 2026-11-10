import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import timedelta
from pathlib import Path

from fastapi import FastAPI
from sqlalchemy import delete, select

from .config import settings
from .db import SessionLocal, init_db
from .models import Attachment, Envelope, now
from .routes import attachments, auth, calls, devices, invites, keys, messages, register

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("hesh")


async def _janitor() -> None:
    """Scarta buste mai ritirate e allegati scaduti. Nessun log con contenuti."""
    while True:
        try:
            async with SessionLocal() as session:
                cutoff = now() - timedelta(days=settings.queue_ttl_days)
                await session.execute(delete(Envelope).where(Envelope.created_at < cutoff))
                old = await session.scalars(select(Attachment).where(Attachment.expires_at < now()))
                for att in old:
                    Path(att.path).unlink(missing_ok=True)
                    await session.delete(att)
                await session.commit()
        except Exception as exc:  # noqa: BLE001
            log.warning("janitor: %s", exc)
        await asyncio.sleep(3600)


@asynccontextmanager
async def lifespan(_: FastAPI):
    await init_db()
    task = asyncio.create_task(_janitor())
    yield
    task.cancel()


app = FastAPI(title="HESH", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(register.router)
app.include_router(invites.router)
app.include_router(keys.router)
app.include_router(messages.router)
app.include_router(attachments.router)
app.include_router(devices.router)
app.include_router(auth.router)
app.include_router(calls.router)


@app.get("/healthz")
async def healthz() -> dict:
    return {"ok": True}
