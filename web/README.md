# hesh.it

File da servire sul dominio principale (non su api.hesh.it):

- `/.well-known/apple-app-site-association` con `Content-Type: application/json`, senza redirect, via HTTPS.
  Serve per: universal link degli inviti (`https://hesh.it/i/<token>`) e passkey (`webcredentials`).

Nginx, dentro il `server` di hesh.it:

```
location = /.well-known/apple-app-site-association {
    alias /opt/hesh/web/.well-known/apple-app-site-association;
    default_type application/json;
}
location ~ ^/i/ {
    return 302 https://hesh.it/;   # senza app installata: pagina di benvenuto
}
```
