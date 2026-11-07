# HESH iOS

Swift 5.10+, SwiftUI, iOS 17+. Un dispositivo per utente nella milestone 1.

## Dipendenze (SPM)

| Package | Uso |
|---|---|
| `https://github.com/signalapp/libsignal` (prodotto `LibSignalClient`) | PQXDH, Double Ratchet, Sender Keys. Verificare al primo build che la versione pubblichi l'xcframework via SPM; in alternativa compilare da `swift/` del repo con il toolchain Rust. |
| `https://github.com/groue/GRDB.swift` + SQLCipher | Store libsignal (identity, session, prekey, sender key) e messaggi locali, cifrati a riposo. |
| `MapKit`, `CoreLocation` | Mappa famiglia, geofence (`CLCircularRegion`), condivisione posizione. |
| `UserNotifications` + Notification Service Extension | Decifra la push a schermo bloccato. |
| `AuthenticationServices` | Passkey. |
| `LocalAuthentication` | Face ID per sblocco locale e chat segrete. |

## Struttura

```
ios/
  HESH/                     app target
    App/                    entry, routing, tema (Dark Matter / Liquid Daylight, HESH Originals)
    Features/
      Onboarding/           ingresso riservato, scansione QR, nome utente, passkey
      Chats/                elenco, chat 1:1, gruppo, chat segreta, allegati
      Calls/                milestone successiva (WebRTC + chiavi derivate dalla sessione)
      Map/                  mappa famiglia, geofence, modalita viaggio
      SOS/                  pressione 3 s, escalation, "emergenza rientrata"
      Settings/             profilo, dispositivi, notifiche, privacy, temi, eliminazione
    Core/
      Crypto/               wrapper LibSignalClient + store GRDB (protocolli *Store di libsignal)
      Network/              client REST + WebSocket, retry, coda offline
      Protocol/             contenuto dei messaggi (vedi Protocol.md)
      Storage/              GRDB, App Group, chiave DB nel Keychain
      Location/             CoreLocation, geofence, throttling
  HESHNotificationService/  NSE: scarica buste, decifra, mostra titolo e corpo
  HESHShared/               framework condiviso tra app e NSE (Crypto, Storage, Protocol)
```

## Vincoli non negoziabili

- La chiave del DB SQLCipher sta nel Keychain con `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, in App Group, senza ACL biometrica: la NSE deve aprirla senza utente presente. Face ID protegge l'apertura dell'app, non la chiave.
- Lo store libsignal e' uno solo, condiviso da app e NSE tramite App Group, con lock su file per evitare ratchet divergenti.
- Il contenuto in chiaro non passa mai per log, analytics o crash report.
- Build riproducibili: hash dell'IPA pubblicato a ogni release.
