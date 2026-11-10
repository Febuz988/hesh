# Contenuto dei messaggi (dentro la busta cifrata)

Il server vede solo `ciphertext`. Dentro, dopo la decifratura libsignal, c'e' un JSON (v1; passera' a protobuf quando il formato si stabilizza).

```json
{ "v": 1, "id": "ulid", "ts": 1762524000000, "kind": "...", "chat": "...", ... }
```

`chat`: `"dm:<username>"` oppure `"g:<group_id>"`.

| kind | campi | note |
|---|---|---|
| `text` | `body`, `reply_to?`, `ephemeral_s?` | |
| `attachment` | `att_id`, `key` (AES-256-GCM, b64), `iv`, `digest`, `mime`, `size`, `name?`, `caption?`, `duration_s?` | vale per foto, video, audio, vocali, file |
| `location` | `lat`, `lon`, `acc_m`, `live?: {until_ts}` | punto singolo o tempo reale |
| `sos` | `lat?`, `lon?`, `acc_m?`, `audio_att?` | spedito con `priority=high` sulla busta |
| `sos_resolved` | `sos_id` | emergenza rientrata |
| `geofence` | `place`, `event: enter\|exit` | solo se abilitato dal membro |
| `checkin` | `place?` | "sono arrivato" |
| `delete` | `target_id`, `scope: me\|everyone` | il client onora |
| `read` | `ids[]` | conferme di lettura, se privacy lo consente |
| `typing` | | solo via WS, mai in coda |
| `profile` | `profile_key`, `avatar_att?`, `birthday?` | profile key per decifrare avatar |
| `contact_request` / `contact_accept` / `contact_block` | | |
| `group_create` | `group_id`, `name`, `members[]`, `avatar_att?`, `settings` | pairwise a ogni membro |
| `group_update` | `group_id`, `patch` | nome, avatar, membri, ruoli, effimeri |
| `sender_key` | `group_id`, `distribution` (SenderKeyDistributionMessage b64) | pairwise, prima del primo messaggio di gruppo |
| `secret_start` / `secret_update` | `ephemeral_s`, `lock: bool` | chat segreta |
| `key_change_ack` | | l'utente ha verificato la nuova chiave |

## Gruppi

Il gruppo e' uno stato replicato lato client. Creazione e modifiche viaggiano pairwise (Double Ratchet) a ogni membro; i messaggi del gruppo usano Sender Keys (un solo ciphertext inviato a N dispositivi con `msg_type=7`). Chi esce: tutti ruotano la sender key. Chi entra: riceve `group_create` + `sender_key` di ciascun membro, senza cronologia salvo scelta esplicita.

## Posizione

Mai nel server. `location` live: un messaggio ogni 60 s o ogni 100 m, con `until_ts`. Il ricevente mostra l'ultimo punto e marca "non aggiornata" oltre 5 minuti. Geofence: solo evento, mai traccia.

## Chiamate (milestone 4)

Segnalazione WebRTC dentro le normali buste Signal 1:1, `chat = dm:<peer>`, tutte con `call_id` (UUID del chiamante):

| kind | campi | priorità busta |
|---|---|---|
| `call_offer` | `sdp`, `video` | `call` (push VoIP) |
| `call_answer` | `sdp` | `silent` |
| `call_ice` | `candidate`, `sdp_mid`, `sdp_mline` | `silent` |
| `call_end` | `reason` (hangup, declined, busy, timeout, failed), `duration_s`, `video` | `silent`, `normal` se `timeout` (chiamata persa) |

`call_end` è l'unico che viene salvato: diventa la riga nel registro chiamate e in chat. Lo manda chi chiude; `timeout` lo manda il chiamante dopo 45 s senza risposta, `busy` il chiamato se è già in chiamata, `declined` il chiamato che rifiuta.

Media: DTLS-SRTP tra i due telefoni; ICE con STUN/TURN presi da `GET /calls/turn` (credenziali temporanee, un'ora). Il server non vede né SDP né media. Offerte più vecchie di 60 s vengono ignorate dal destinatario.

Priorità busta (unico metadato visibile al server): `normal` alert, `high` SOS, `call` push VoIP, `silent` push in background senza avviso.
