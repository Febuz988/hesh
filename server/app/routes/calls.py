"""Chiamate: il server non vede ne' segnalazione ne' media. Fornisce solo le
credenziali temporanee per il TURN (coturn, schema REST "use-auth-secret"):
username = <scadenza unix>:<id utente>, password = base64(HMAC-SHA1(secret, username)).
La segnalazione (offer/answer/ICE) viaggia dentro le normali buste Signal."""
import base64
import hashlib
import hmac
import time
from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import current_device
from ..config import settings
from ..models import Device

router = APIRouter(prefix="/calls", tags=["calls"])
Dev = Annotated[Device, Depends(current_device)]


@router.get("/turn")
async def turn_credentials(dev: Dev) -> dict:
    servers: list[dict] = [{"urls": ["stun:stun.l.google.com:19302"]}]
    if settings.turn_host and settings.turn_secret:
        expiry = int(time.time()) + settings.turn_ttl_s
        username = f"{expiry}:{dev.user_id}"
        digest = hmac.new(settings.turn_secret.encode(), username.encode(), hashlib.sha1).digest()
        password = base64.b64encode(digest).decode()
        h = settings.turn_host
        servers.insert(0, {"urls": [f"stun:{h}:3478"]})
        servers.append({
            "urls": [f"turn:{h}:3478?transport=udp", f"turn:{h}:3478?transport=tcp", f"turns:{h}:5349?transport=tcp"],
            "username": username,
            "credential": password,
        })
    return {"ice_servers": servers, "ttl_s": settings.turn_ttl_s}
