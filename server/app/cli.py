"""hesh-admin: procedura controllata per il primo membro. Non esiste un percorso
HTTP equivalente: il primo invito nasce solo dalla shell del server."""
import asyncio
from datetime import timedelta

import typer
from sqlalchemy import select

from .auth import new_token, sha256
from .config import settings
from .db import SessionLocal, init_db
from .models import Invite, User, now

app = typer.Typer(add_completion=False, help="Amministrazione HESH")


async def _bootstrap(username: str) -> None:
    await init_db()
    async with SessionLocal() as session:
        if await session.scalar(select(User.id).limit(1)):
            typer.echo("Esistono gia' utenti: usa l'app per generare inviti.")
            raise typer.Exit(1)
        # Utente "sistema" emittente del primo invito: viene sostituito dal primo
        # registrato (che diventa admin). Qui creiamo solo l'invito, con issuer
        # fittizio che il primo /register ripulisce.
        seed = User(username="__bootstrap__", identity_key=b"\x00", registration_id=1, is_admin=True)
        session.add(seed)
        await session.flush()
        token = new_token()
        session.add(Invite(token_hash=sha256(token), issuer_id=seed.id, label=f"bootstrap {username}",
                           expires_at=now() + timedelta(hours=settings.invite_ttl_hours)))
        await session.commit()
    typer.echo(f"Invito bootstrap per {username} (valido {settings.invite_ttl_hours} h):")
    typer.echo(f"  hesh://invite/{token}")
    typer.echo("Dopo la registrazione esegui: hesh-admin finalize")


async def _finalize() -> None:
    async with SessionLocal() as session:
        seed = await session.scalar(select(User).where(User.username == "__bootstrap__"))
        first = await session.scalar(select(User).where(User.username != "__bootstrap__").order_by(User.created_at).limit(1))
        if seed is None or first is None:
            typer.echo("Niente da finalizzare.")
            return
        first.is_admin = True
        await session.delete(seed)
        await session.commit()
    typer.echo(f"{first.username} e' amministratore. Utente bootstrap rimosso.")


@app.command()
def bootstrap(username: str = typer.Option(..., help="nome utente atteso per il primo membro")) -> None:
    asyncio.run(_bootstrap(username))


@app.command()
def finalize() -> None:
    asyncio.run(_finalize())


if __name__ == "__main__":
    app()
