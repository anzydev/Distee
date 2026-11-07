#!/bin/bash
# Stops any running Distee relay, cloudflared tunnel, or Mac agent
echo "==> Stopping Distee services..."
killall Distee 2>/dev/null || true
killall cloudflared 2>/dev/null || true
lsof -ti:8799 2>/dev/null | xargs kill -9 2>/dev/null || true
rm -f ~/.distee_web_url /tmp/distee_relay.log /tmp/distee_tunnel.log
echo "==> All Distee services stopped."

