# API server HESH v0.1 (milestone 1)

Tutti i binari sono base64. Autenticazione: `Authorization: Bearer <token>` ricevuto a `/register`.

| Metodo | Percorso | Auth | Scopo |
|---|---|---|---|
| POST | `/register` | no (rate-limited) | Riscatta un invito, crea utente + dispositivo 1, carica identity key, signed prekey, kyber prekey, one-time prekeys. Restituisce il bearer. Atomico: un invito monouso non crea due account. |
| POST | `/invites` | si | Genera invito. Il token compare solo in questa risposta (`hesh://invite/<token>`); il server salva l'hash. |
| GET | `/invites` | si | I miei inviti con stato `active/used/expired/revoked`. |
| DELETE | `/invites/{id}` | si | Revoca. |
| GET | `/keys/lookup/{username}` | si | Identity key e dispositivi di un membro (richieste di contatto). |
| GET | `/keys/bundle/{username}/{device}` | si | Prekey bundle; consuma una one-time prekey. |
| GET | `/keys/count` | si | Quante one-time prekey restano; `low` sotto 20. |
| PUT | `/keys/replenish` | si | Ricarica one-time e ruota signed/kyber prekey. |
| POST | `/messages` | si | Batch di buste `{to_username,to_device_id,msg_type,ciphertext,priority}`. Spinge via WS se online, altrimenti APNs. `priority=high` e' l'unico metadato SOS. |
| GET | `/messages` | si | Coda in attesa. |
| POST | `/messages/ack` | si | Cancella le buste ricevute. |
| WS | `/messages/stream?token=` | si | Consegna live; `{"type":"ack","ids":[...]}` dal client. |
| POST | `/attachments` | si | Body = blob gia' cifrato. Restituisce id. |
| GET | `/attachments/{id}` | si | Scarica il blob. |
| DELETE | `/attachments/{id}` | si | Solo proprietario. |
| GET | `/devices` | si | Dispositivi dell'account. |
| PUT | `/devices/me/apns` | si | Aggiorna token APNs. |
| DELETE | `/devices/{id}` | si | Revoca un dispositivo. |
| POST | `/devices/me/logout` | si | Revoca la sessione corrente. |
| DELETE | `/devices/me/account` | si | Disattiva l'account e revoca tutto. |

Tipi `msg_type` (libsignal `CiphertextMessage.Type`): 3 = PreKeySignalMessage, 2 = SignalMessage, 7 = SenderKeyMessage, 8 = PlaintextContent (solo per DecryptionError).

Il contenuto decifrato (testo, gruppo, posizione, SOS, delete, profile key, avatar id) e' un protobuf/JSON definito dal client: `ios/Protocol.md`.

## Chiamate

- `GET /calls/turn` → `{ "ice_servers": [{urls, username?, credential?}], "ttl_s": 3600 }`. Credenziali coturn REST (`<scadenza>:<user_id>` + HMAC-SHA1 del segreto condiviso). Senza `HESH_TURN_HOST` restituisce solo STUN pubblico.
- `PUT /devices/me/voip` `{ "voip_token": "<hex>" }`: token PushKit, usato solo per buste con `priority = call`.

Priorità busta: `normal | high | call | silent`. `call` → push VoIP (topic `<bundle>.voip`), `silent` → push `content-available` senza alert.
