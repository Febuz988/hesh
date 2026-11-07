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
