"""APNs token-based. Il payload non contiene mai contenuto: solo "hai messaggi"
e, per l'SOS, il livello di interruzione alto. La NSE del client scarica e decifra."""
import logging

from .config import settings

log = logging.getLogger("hesh.push")
_client = None


def _get_client():
    global _client
    if _client is None and settings.apns_enabled:
        from aioapns import APNs

        with open(settings.apns_key_path, encoding="utf-8") as f:
            key_pem = f.read()
        _client = APNs(
            key=key_pem,
            key_id=settings.apns_key_id,
            team_id=settings.apns_team_id,
            topic=settings.apns_topic,
            use_sandbox=settings.apns_sandbox,
        )
    return _client


async def notify(apns_token: str | None, priority: str) -> None:
    if not apns_token:
        return
    client = _get_client()
    if client is None:
        log.debug("push disattivato (APNs non configurato)")
        return
    from aioapns import NotificationRequest, PushType

    sos = priority == "high"
    payload = {
        "aps": {
            "mutable-content": 1,
            "alert": {"title": "HESH", "body": "Nuovo messaggio"},
            "sound": "sos.caf" if sos else "default",
            "interruption-level": "time-sensitive" if sos else "active",
        },
        "hesh": {"kind": "sos" if sos else "message"},
    }
    req = NotificationRequest(
        device_token=apns_token,
        message=payload,
        push_type=PushType.ALERT,
        priority=10,
    )
    try:
        res = await client.send_notification(req)
        if not res.is_successful:
            log.warning("push fallito: %s", res.description)
    except Exception as exc:  # noqa: BLE001
        log.warning("push errore: %s", exc)
