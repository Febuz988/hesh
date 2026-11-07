"""Registro delle connessioni WebSocket attive, una per dispositivo.
Quando arriva una busta per un dispositivo connesso, la spingiamo subito."""
import asyncio
import json

from fastapi import WebSocket


class Hub:
    def __init__(self) -> None:
        self._conns: dict[str, WebSocket] = {}
        self._lock = asyncio.Lock()

    async def connect(self, device_pk: str, ws: WebSocket) -> None:
        async with self._lock:
            old = self._conns.pop(device_pk, None)
            self._conns[device_pk] = ws
        if old is not None:
            try:
                await old.close(code=4000, reason="sostituita")
            except Exception:  # noqa: BLE001
                pass

    async def disconnect(self, device_pk: str, ws: WebSocket) -> None:
        async with self._lock:
            if self._conns.get(device_pk) is ws:
                del self._conns[device_pk]

    async def push(self, device_pk: str, payload: dict) -> bool:
        ws = self._conns.get(device_pk)
        if ws is None:
            return False
        try:
            await ws.send_text(json.dumps(payload))
            return True
        except Exception:  # noqa: BLE001
            await self.disconnect(device_pk, ws)
            return False

    def is_online(self, device_pk: str) -> bool:
        return device_pk in self._conns


hub = Hub()
