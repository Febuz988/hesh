"""Schema del server. Nessun campo contiene materiale in chiaro dell'utente
oltre al nome utente: chiavi pubbliche, buste cifrate, blob cifrati."""
from __future__ import annotations

import secrets
from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, Index, Integer, LargeBinary, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def now() -> datetime:
    return datetime.now(timezone.utc)


def aware(dt: datetime) -> datetime:
    """SQLite restituisce datetime naive: li trattiamo come UTC."""
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def new_id() -> str:
    return secrets.token_urlsafe(16)


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    username: Mapped[str] = mapped_column(String(20), unique=True, index=True)
    identity_key: Mapped[bytes] = mapped_column(LargeBinary)  # chiave pubblica di identita (libsignal)
    registration_id: Mapped[int] = mapped_column(Integer)
    is_admin: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    devices: Mapped[list[Device]] = relationship(back_populates="user", cascade="all, delete-orphan")


class Device(Base):
    """Un dispositivo = una sessione. Milestone 1: un dispositivo per utente (device_id=1)."""
    __tablename__ = "devices"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    device_id: Mapped[int] = mapped_column(Integer, default=1)
    name: Mapped[str] = mapped_column(String(64), default="iPhone")
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)  # sha256 del bearer
    apns_token: Mapped[str | None] = mapped_column(String(200), nullable=True)
    voip_token: Mapped[str | None] = mapped_column(String(200), nullable=True)   # PushKit, solo per le chiamate
    signed_prekey_id: Mapped[int] = mapped_column(Integer)
    signed_prekey: Mapped[bytes] = mapped_column(LargeBinary)
    signed_prekey_signature: Mapped[bytes] = mapped_column(LargeBinary)
    kyber_prekey_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    kyber_prekey: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    kyber_prekey_signature: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    user: Mapped[User] = relationship(back_populates="devices")
    one_time_prekeys: Mapped[list[OneTimePreKey]] = relationship(cascade="all, delete-orphan")


class OneTimePreKey(Base):
    __tablename__ = "one_time_prekeys"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_pk: Mapped[str] = mapped_column(ForeignKey("devices.id", ondelete="CASCADE"), index=True)
    key_id: Mapped[int] = mapped_column(Integer)
    public_key: Mapped[bytes] = mapped_column(LargeBinary)


class Invite(Base):
    __tablename__ = "invites"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)  # mai il token
    issuer_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    label: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    redeemed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    redeemed_by: Mapped[str | None] = mapped_column(String(32), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    @property
    def status(self) -> str:
        if self.revoked_at:
            return "revoked"
        if self.redeemed_at:
            return "used"
        if aware(self.expires_at) < now():
            return "expired"
        return "active"


class Envelope(Base):
    """Busta cifrata in coda. Il server la cancella all'ack del destinatario."""
    __tablename__ = "envelopes"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    to_device: Mapped[str] = mapped_column(ForeignKey("devices.id", ondelete="CASCADE"), index=True)
    from_user: Mapped[str] = mapped_column(String(32))
    from_device_id: Mapped[int] = mapped_column(Integer, default=1)
    msg_type: Mapped[int] = mapped_column(Integer)  # libsignal CiphertextMessage type (prekey / whisper / senderkey)
    ciphertext: Mapped[bytes] = mapped_column(LargeBinary)
    priority: Mapped[str] = mapped_column(String(8), default="normal")  # normal | high  (unico metadato SOS)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, index=True)


class Attachment(Base):
    __tablename__ = "attachments"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(String(32))
    size: Mapped[int] = mapped_column(Integer)
    path: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Passkey(Base):
    __tablename__ = "passkeys"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    credential_id: Mapped[bytes] = mapped_column(LargeBinary, unique=True)
    public_key: Mapped[bytes] = mapped_column(LargeBinary)
    sign_count: Mapped[int] = mapped_column(Integer, default=0)
    name: Mapped[str] = mapped_column(String(64), default="Passkey")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class AuthChallenge(Base):
    """Challenge WebAuthn in attesa; scade in 5 minuti."""
    __tablename__ = "auth_challenges"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    challenge: Mapped[bytes] = mapped_column(LargeBinary)
    user_id: Mapped[str | None] = mapped_column(String(32), nullable=True)
    kind: Mapped[str] = mapped_column(String(16))  # register | login
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Backup(Base):
    """Blob cifrato dal client con la chiave derivata dalle 12 parole."""
    __tablename__ = "backups"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    blob: Mapped[bytes] = mapped_column(LargeBinary)
    version: Mapped[int] = mapped_column(Integer, default=1)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


Index("ix_envelope_dev_created", Envelope.to_device, Envelope.created_at)
