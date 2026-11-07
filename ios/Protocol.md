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
