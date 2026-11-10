# Deploy su VPS (convive con altri servizi)

Il server HESH ascolta solo su `127.0.0.1:8087`; Nginx fa da fronte TLS su un sottodominio dedicato. Database Postgres separato in un container proprio.

```bash
# sulla VPS
git clone <repo> /opt/hesh && cd /opt/hesh/server/deploy
mkdir -p secrets && chmod 700 secrets
# copiare la chiave APNs .p8 in secrets/apns.p8
cat > .env <<EOF
HESH_DB_PASSWORD=$(openssl rand -hex 24)
HESH_APNS_KEY_ID=XXXXXXXXXX
HESH_APNS_TEAM_ID=XXXXXXXXXX
HESH_APNS_TOPIC=it.hesh.app
HESH_APNS_SANDBOX=false
EOF
docker compose up -d --build

# Nginx
sed "s/SERVER_NAME/hesh.TUODOMINIO/g" nginx-hesh.conf | sudo tee /etc/nginx/sites-available/hesh
sudo ln -s /etc/nginx/sites-available/hesh /etc/nginx/sites-enabled/hesh
sudo certbot --nginx -d hesh.TUODOMINIO
sudo nginx -t && sudo systemctl reload nginx

# primo membro: l'invito bootstrap nasce solo da qui
docker compose exec api hesh-admin bootstrap --username fabio
# ...registrazione dall'app, poi:
docker compose exec api hesh-admin finalize
```

## Cosa controllare prima di aprire ad altri

- `access_log off` in Nginx: il server non deve tenere traccia di chi parla con chi.
- Backup: solo `hesh_db` (chiavi pubbliche, inviti, metadati). Gli allegati sono blob cifrati a scadenza: non serve salvarli.
- Il job interno scarta buste non ritirate e allegati dopo `HESH_QUEUE_TTL_DAYS`.
- Mai esporre la porta 8087 oltre il loopback.

## Chiamate (coturn)

Il server non vede i media: coturn fa solo da relay quando i due telefoni non si raggiungono direttamente.

1. `.env`: aggiungere
   ```
   HESH_TURN_HOST=api.hesh.it
   HESH_TURN_SECRET=$(openssl rand -hex 32)
   HESH_PUBLIC_IP=217.160.116.248
   ```
2. Firewall IONOS (pannello, non solo ufw): aprire **3478 TCP+UDP**, **5349 TCP**, **49160-49400 UDP**.
3. `docker compose up -d turn api`
4. Verifica: `docker compose logs turn | tail`, poi dall'app una chiamata con Wi-Fi spento da un lato.
