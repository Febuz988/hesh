import base64
import re
from typing import Annotated

from pydantic import BaseModel, Field, field_validator

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9.]{2,19}$")


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def unb64(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


B64 = Annotated[str, Field(min_length=4, max_length=8192)]


class PreKeyIn(BaseModel):
    key_id: int
    public_key: B64


class RegisterIn(BaseModel):
    invite_token: str = Field(min_length=16, max_length=128)
    username: str
    device_name: str = Field(default="iPhone", max_length=64)
    identity_key: B64
    registration_id: int = Field(ge=1, le=16380)
    signed_prekey_id: int
    signed_prekey: B64
    signed_prekey_signature: B64
    kyber_prekey_id: int | None = None
    kyber_prekey: B64 | None = None
    kyber_prekey_signature: B64 | None = None
    one_time_prekeys: list[PreKeyIn] = Field(default_factory=list, max_length=200)
    apns_token: str | None = Field(default=None, max_length=200)

    @field_validator("username")
    @classmethod
    def _username(cls, v: str) -> str:
        v = v.strip().lower()
        if not USERNAME_RE.match(v):
            raise ValueError("nome utente non valido: 3-20 caratteri, lettere minuscole, numeri, punto")
        return v


class RegisterOut(BaseModel):
    user_id: str
    username: str
    device_id: int
    token: str


class InviteCreateIn(BaseModel):
    label: str = Field(default="", max_length=64)


class InviteOut(BaseModel):
    id: str
    label: str
    status: str
    created_at: str
    expires_at: str
    token: str | None = None  # restituito una sola volta, alla creazione
    link: str | None = None


class PreKeyBundleOut(BaseModel):
    user_id: str
    username: str
    device_id: int
    registration_id: int
    identity_key: str
    signed_prekey_id: int
    signed_prekey: str
    signed_prekey_signature: str
    kyber_prekey_id: int | None
    kyber_prekey: str | None
    kyber_prekey_signature: str | None
    one_time_prekey_id: int | None
    one_time_prekey: str | None


class ReplenishIn(BaseModel):
    signed_prekey_id: int | None = None
    signed_prekey: B64 | None = None
    signed_prekey_signature: B64 | None = None
    kyber_prekey_id: int | None = None
    kyber_prekey: B64 | None = None
    kyber_prekey_signature: B64 | None = None
    one_time_prekeys: list[PreKeyIn] = Field(default_factory=list, max_length=200)


class EnvelopeIn(BaseModel):
    to_username: str
    to_device_id: int = 1
    msg_type: int = Field(ge=1, le=10)
    ciphertext: Annotated[str, Field(max_length=1_000_000)]
    priority: str = Field(default="normal", pattern="^(normal|high)$")


class EnvelopeBatchIn(BaseModel):
    envelopes: list[EnvelopeIn] = Field(min_length=1, max_length=64)


class EnvelopeOut(BaseModel):
    id: str
    from_username: str
    from_device_id: int
    msg_type: int
    ciphertext: str
    priority: str
    created_at: str


class AckIn(BaseModel):
    ids: list[str] = Field(min_length=1, max_length=500)


class UserLookupOut(BaseModel):
    user_id: str
    username: str
    identity_key: str
    devices: list[int]


class DeviceOut(BaseModel):
    id: str
    device_id: int
    name: str
    created_at: str
    last_seen_at: str
    current: bool


class ApnsIn(BaseModel):
    apns_token: str = Field(max_length=200)
