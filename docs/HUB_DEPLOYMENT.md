# Hub deployment checklist

The Hub is a coordination service. Keep the Engine and worker hosts private.

## Local smoke test

```bash
COLMEIA_ROOT=/srv/colmeia \
COLMEIA_HUB_HOST=127.0.0.1 \
COLMEIA_HUB_PORT=9620 \
COLMEIA_HUB_TOKEN='replace-me' \
.build/debug/colmeia-hub
```

The app can connect to `ws://127.0.0.1:9620` for local development.

## WSS

For a direct macOS WSS listener, provide a PKCS#12 identity:

```bash
COLMEIA_HUB_WSS=1 \
COLMEIA_HUB_TLS_P12=/etc/colmeia/hub.p12 \
COLMEIA_HUB_TLS_PASSWORD='from-secret-manager' \
COLMEIA_HUB_TLS_HOSTNAME=hub.example.com \
COLMEIA_HUB_HOST=0.0.0.0 \
COLMEIA_HUB_PORT=9620 \
COLMEIA_HUB_TOKEN='from-secret-manager' \
.build/debug/colmeia-hub
```

The public WSS listener proxies to a loopback-only TCP backend. If the
certificate is missing or the listener fails, the process exits instead of
silently binding a different port.

## Before exposing it

- Put the service under a dedicated OS user.
- Store the token and PKCS#12 password outside the repository.
- Restrict ingress to the reverse proxy or trusted network.
- Back up `COLMEIA_ROOT` and test restore.
- Monitor process health, disk space, failed authentication, and rate limits.
- Run the full suite with `./test.sh` before publishing a release.
