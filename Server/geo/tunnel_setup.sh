#!/bin/bash
# Create the Cloudflare Tunnel for geo.agstatus.online -> nginx front (127.0.0.1:8088),
# run it as a system service, then remove the account-level certificate from this VM.
# Needs a fresh `cloudflared tunnel login` (the owner authorizes the zone in the browser).
# Safe to re-run: an existing tunnel and installed credentials are kept.
set -euo pipefail
HOST=geo.agstatus.online
NAME=tripatlas-geo
CERT="$HOME/.cloudflared/cert.pem"
[ -f "$CERT" ] || { echo "no cert.pem: run 'cloudflared tunnel login' first"; exit 1; }
# The account certificate can create tunnels and DNS records for the whole zone; the running
# tunnel only needs its own credentials, so the certificate leaves this VM however the script ends.
trap 'shred -u "$CERT" 2>/dev/null || true' EXIT

cloudflared tunnel list -o json | jq -e --arg n "$NAME" '.[] | select(.name==$n)' >/dev/null 2>&1 \
  && echo "tunnel $NAME already exists" || cloudflared tunnel create "$NAME"
TID=$(cloudflared tunnel list -o json | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id')
echo "tunnel id: $TID"
cloudflared tunnel route dns "$NAME" "$HOST" || echo "DNS route not changed (already set?)"

sudo mkdir -p /etc/cloudflared
if sudo test -f "/etc/cloudflared/$TID.json"; then
  echo "tunnel credentials already installed"
else
  sudo install -m 600 "$HOME/.cloudflared/$TID.json" "/etc/cloudflared/$TID.json"
fi
rm -f "$HOME/.cloudflared/$TID.json"
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $TID
credentials-file: /etc/cloudflared/$TID.json
no-autoupdate: true
ingress:
  - hostname: $HOST
    service: http://127.0.0.1:8088
  - service: http_status:404
EOF
sudo cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
systemctl is-enabled --quiet cloudflared 2>/dev/null \
  || sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl restart cloudflared
sleep 5
systemctl is-active cloudflared
echo "done; cert.pem is removed on exit, credentials only in /etc/cloudflared"
