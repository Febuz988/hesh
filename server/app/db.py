from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from .config import settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(settings.database_url, echo=False)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def init_db() -> None:
    from . import models  # noqa: F401  registra i modelli

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    # Colonne aggiunte dopo la prima release: ALTER additivi, idempotenti.
    from sqlalchemy import text
    for stmt in ("ALTER TABLE devices ADD COLUMN voip_token VARCHAR(200)",):
        try:
            async with engine.begin() as conn:
                await conn.execute(text(stmt))
        except Exception:  # noqa: BLE001  colonna gia' presente
            pass


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
