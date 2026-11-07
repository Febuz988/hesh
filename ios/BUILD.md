# Compilare HESH iOS

```bash
brew install xcodegen
cd ios
xcodegen generate
open HESH.xcodeproj
```

In Xcode:
1. Target HESH e HESHNotificationService → Signing & Capabilities → Team: il tuo Team ID. Automatic signing crea i profili con Push, App Groups (`group.it.hesh`) e Associated Domains (`applinks:hesh.it`).
2. Prima build: SPM scarica `libsignal` e `GRDB`. libsignal pubblica il binario Swift; se Xcode chiede il toolchain Rust, allineare la versione in `project.yml` a un tag che fornisce l'xcframework.
3. Esegui su iPhone fisico (la fotocamera per il QR e le push non funzionano nel simulatore).

## Primo accesso

Sulla VPS: `docker compose exec api hesh-admin bootstrap --username fabio` → stampa `hesh://invite/<token>`. In app: "Ho un link di invito", incolla, scegli il nome utente. Poi `hesh-admin finalize`.

## Dove aspettarsi errori di compilazione

Lo scheletro e' scritto senza poter compilare qui. I punti che dipendono dalla versione esatta di libsignal:

- `SignalStore.swift`: firme dei protocolli `IdentityKeyStore` (il tipo di ritorno di `saveIdentity` e' `IdentityChange` nelle versioni recenti, `Bool` nelle vecchie), `SenderKeyStore`, `KyberPreKeyStore`.
- `CryptoService.swift`: inizializzatori di `PreKeyBundle` (varianti con/senza one-time e kyber), `SignedPreKeyRecord`, `KyberPreKeyRecord`, `KEMKeyPair`.
- `CiphertextMessage.MessageType` raw values: preKey = 3, whisper = 2, senderKey = 7. Devono coincidere con `msg_type` lato server (`server/API.md`).

Tutto il resto (GRDB, SwiftUI, AVFoundation, CoreLocation) e' API stabile.

## Universal link

Per `https://hesh.it/i/<token>` servire su hesh.it il file `/.well-known/apple-app-site-association` (Content-Type `application/json`):

```json
{"applinks":{"apps":[],"details":[{"appID":"TEAMID.it.hesh.app","paths":["/i/*"]}]}}
```
