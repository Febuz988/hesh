"""APNs token-based. Il payload non contiene mai contenuto.

Quattro casi, scelti dal campo `priority` della busta (unico metadato in chiaro):
- normal: alert "Nuovo messaggio", la NSE scarica e decifra.
- high:   come normal ma time-sensitive e suono SOS.
- call:   push VoIP (PushKit) sul token voip: l'app si sveglia e passa a CallKit.
- silent: background push senza alert (conferme di lettura, ICE, typing...).
"""
import logging

from .config import settings
from .models import Device

log = logging.getLogger("hesh.push")
_alert_client = None
_voip_client = None


def _client(voip: bool):
    global _alert_client, _voip_client
    if not settings.apns_enabled:
        return None
    if voip and _voip_client is None or not voip and _alert_client is None:
        from aioapns import APNs

        with open(settings.apns_key_path, encoding="utf-8") as f:
            key_pem = f.read()
        client = APNs(
            key=key_pem,
            key_id=settings.apns_key_id,
            team_id=settings.apns_team_id,
            topic=settings.apns_topic + (".voip" if voip else ""),
            use_sandbox=settings.apns_sandbox,
        )
        if voip:
            _voip_client = client
        else:
            _alert_client = client
    return _voip_client if voip else _alert_client


async def notify(device: Device, priority: str) -> None:
    from aioapns import NotificationRequest, PushType

    if priority == "call":
        if not device.voip_token:
            # Senza token VoIP ripieghiamo su un alert normale: meglio di niente.
            return await notify(device, "normal")
        client = _client(voip=True)
        if client is None:
            return
        req = NotificationRequest(device_token=device.voip_token, message={"hesh": {"kind": "call"}}, push_type=PushType.VOIP, priority=10)
    else:
        if not device.apns_token:
            return
        client = _client(voip=False)
        if client is None:
            log.debug("push disattivato (APNs non configurato)")
            return
        if priority == "silent":
            payload = {"aps": {"content-available": 1}, "hesh": {"kind": "silent"}}
            req = NotificationRequest(device_token=device.apns_token, message=payload, push_type=PushType.BACKGROUND, priority=5)
        else:
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
            req = NotificationRequest(device_token=device.apns_token, message=payload, push_type=PushType.ALERT, priority=10)
    try:
        res = await client.send_notification(req)
        if not res.is_successful:
            log.warning("push fallito (%s): %s", priority, res.description)
    except Exception as exc:  # noqa: BLE001
        log.warning("push errore: %s", exc)
