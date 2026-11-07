# HESH

Messaggistica privata per un cerchio di fiducia. End-to-end con Signal Protocol, accesso solo su invito, mappa famiglia e SOS al gruppo.

- `server/` — backend FastAPI. Non tocca mai crittografia: conserva prekey bundle opachi, accoda buste cifrate, invia push.
- `ios/` — client Swift/SwiftUI con `LibSignalClient`.
- `docs/SPEC.md` — specifiche funzionali.
- `design/` — tavole grafiche e riferimenti visivi.

## Principi

1. Il server non può leggere messaggi, allegati, gruppi, posizioni o avatar. Vede solo chi esiste, quando invia, a chi consegna e quanto pesa.
2. Nessun numero di telefono, nessuna email. L'identità è il nome utente più la chiave di identità generata sul dispositivo.
3. Nessun percorso pubblico di registrazione. Ogni account nasce da un invito monouso, verificato dal server.
4. Ogni controllo di accesso vive sul server. Nascondere un pulsante non è un controllo.

## Avvio rapido (sviluppo)

```bash
cd server
python -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env
hesh-admin bootstrap --username fabio      # crea il primo account e stampa il suo invito
uvicorn app.main:app --reload
pytest
```

## Produzione

Vedi `server/deploy/README.md` (docker compose + Nginx + TLS).

## Licenza

AGPL-3.0-or-later. Vedi `LICENSE`.
