#!/bin/bash
set -e
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "=========================================================="
echo " 🛡️ Starting Distee Cross-Network Relay & Web App"
echo "=========================================================="

# 1. Build the production web bundle
echo "==> Building web frontend bundle..."
(cd web && npm run build >/dev/null 2>&1)

# 2. Clean up any existing instances
killall cloudflared 2>/dev/null || true
lsof -ti:8799 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

# 3. Launch Node.js Relay Server in background
nohup node relay/server.js > /tmp/distee_relay.log 2>&1 &
RELAY_PID=$!

# 4. Launch Cloudflare HTTPS Tunnel in background (for Cellular 5G + Wi-Fi)
CLOUDFLARED_BIN="$ROOT_DIR/bin/cloudflared"
PUBLIC_URL=""

if [ -x "$CLOUDFLARED_BIN" ]; then
    echo "==> Connecting zero-cost Cloudflare HTTPS tunnel..."
    nohup "$CLOUDFLARED_BIN" tunnel --url http://localhost:8799 > /tmp/distee_tunnel.log 2>&1 &
    TUNNEL_PID=$!

    # Wait up to 15 seconds for the public trycloudflare HTTPS URL
    for i in {1..30}; do
        PUBLIC_URL=$(grep -o "https://[a-zA-Z0-9-]*\.trycloudflare\.com" /tmp/distee_tunnel.log 2>/dev/null | head -1 || true)
        if [ -n "$PUBLIC_URL" ]; then
            break
        fi
        sleep 0.5
    done
fi

LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")

if [ -n "$PUBLIC_URL" ]; then
    echo "$PUBLIC_URL" > ~/.distee_web_url
    echo ""
    echo "  ========================================================"
    echo "  🌐 PUBLIC HTTPS URL (Works on Cellular 5G & Wi-Fi):"
    echo "     $PUBLIC_URL"
    echo "  ========================================================"
    echo ""
    echo "  🔒 Secure Context: Active (WebCrypto + Camera enabled)"
    echo "  📶 Cross-Network:  Mac on Wi-Fi <--> Phone on 5G/4G"
else
    echo "http://${LAN_IP}:8799" > ~/.distee_web_url
    echo ""
    echo "  📱 Local Wi-Fi URL: http://${LAN_IP}:8799"
    echo "  ⚠️ Cloudflare tunnel unavailable; connect phone to same Wi-Fi."
fi

echo "  💻 Mac Local Relay: ws://127.0.0.1:8799"
echo "  🛑 To stop services: ./stop.sh"
echo "=========================================================="
echo "  Distee background services are live!"
echo "=========================================================="
