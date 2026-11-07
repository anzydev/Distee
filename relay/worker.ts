/**
 * Cloudflare Worker + Durable Object implementation of Distee Relay.
 * Provides ₹0 serverless deployment on Cloudflare Free Tier.
 *
 * Mirrors relay/server.js: a Mac only becomes the room's device after it proves it owns
 * the device key (challenge-response), and the public key must hash to the device id.
 */

export interface Env {
  DEVICE_ROOM: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok', service: 'distee-cf-relay' }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Match /ws/device/:deviceId or /ws/mobile/:deviceId
    const match = url.pathname.match(/^\/ws\/(device|mobile)\/([a-z0-9]{16})$/i);
    if (!match) {
      return new Response('Not Found. Use /ws/device/:id or /ws/mobile/:id', { status: 404 });
    }

    const deviceId = match[2];
    const id = env.DEVICE_ROOM.idFromName(deviceId.toLowerCase());
    const room = env.DEVICE_ROOM.get(id);

    return room.fetch(request);
  },
};

const B32 = 'abcdefghijklmnopqrstuvwxyz234567';

function base32Lower(buf: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function base64UrlToBytes(input: string): Uint8Array {
  let b64 = input.replace(/-/g, '+').replace(/_/g, '/');
  while (b64.length % 4 !== 0) b64 += '=';
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Converts an ASN.1 DER ECDSA signature (CryptoKit) to IEEE P1363 r||s (WebCrypto). */
function derToP1363(der: Uint8Array): Uint8Array {
  if (der.length === 64) return der;
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error('Invalid DER sequence');
  if (der[offset] & 0x80) offset += (der[offset] & 0x7f) + 1;
  else offset++;

  const readInt = (): Uint8Array => {
    if (der[offset++] !== 0x02) throw new Error('Invalid DER integer');
    const len = der[offset++];
    let value = der.slice(offset, offset + len);
    offset += len;
    while (value.length > 32 && value[0] === 0x00) value = value.slice(1);
    if (value.length > 32) throw new Error('DER integer too large');
    const padded = new Uint8Array(32);
    padded.set(value, 32 - value.length);
    return padded;
  };

  const r = readInt();
  const s = readInt();
  const raw = new Uint8Array(64);
  raw.set(r, 0);
  raw.set(s, 32);
  return raw;
}

/**
 * Verifies the Mac's challenge response: the public key must hash to the device id and
 * the signature must cover the relay's challenge, the device id and the epoch.
 */
async function verifyDeviceAuth(deviceId: string, challenge: string, data: any): Promise<boolean> {
  try {
    if (typeof data.pk !== 'string' || typeof data.sig !== 'string' || typeof data.e !== 'number') {
      return false;
    }
    const pub = base64UrlToBytes(data.pk);
    if (pub.length !== 65 || pub[0] !== 0x04) return false;

    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', pub));
    const derived = base32Lower(digest).slice(0, 16);
    if (derived !== deviceId) return false;

    const key = await crypto.subtle.importKey(
      'raw',
      pub,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify']
    );
    const input = new TextEncoder().encode(`distee-auth-v1\n${challenge}\n${deviceId}\n${data.e}`);
    const signature = derToP1363(base64UrlToBytes(data.sig));
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signature, input);
  } catch {
    return false;
  }
}

export class DeviceRoom implements DurableObject {
  private deviceWs: WebSocket | null = null;
  private mobileSockets: Set<WebSocket> = new Set();
  private deviceId: string = '';
  private authenticated: boolean = false;

  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/ws\/(device|mobile)\/([a-z0-9]{16})$/i);
    if (!match) return new Response('Invalid path', { status: 400 });

    const role = match[1].toLowerCase();
    this.deviceId = match[2].toLowerCase();

    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (role === 'device') {
      this.handleDevice(server);
    } else {
      this.handleMobile(server);
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private handleDevice(ws: WebSocket) {
    ws.accept();

    // The new socket only replaces the current Mac after it proves it owns the device key.
    let authenticated = false;
    const challenge = bytesToBase64Url(crypto.getRandomValues(new Uint8Array(32)));
    ws.send(JSON.stringify({ t: 'hello', challenge, d: this.deviceId, ts: Math.floor(Date.now() / 1000) }));

    // Drop sockets that never complete the handshake.
    const handshakeTimer = setTimeout(() => {
      if (!authenticated) {
        try { ws.close(4408, 'AUTH_TIMEOUT'); } catch {}
      }
    }, 15000);

    ws.addEventListener('message', async (event) => {
      try {
        const data = JSON.parse(event.data as string);

        if (!authenticated) {
          if (data.t !== 'auth' || !(await verifyDeviceAuth(this.deviceId, challenge, data))) {
            ws.send(JSON.stringify({ t: 'error', reason: 'BAD_SIGNATURE' }));
            ws.close(4403, 'BAD_SIGNATURE');
            return;
          }
          authenticated = true;
          clearTimeout(handshakeTimer);

          if (this.deviceWs && this.deviceWs !== ws) {
            try { this.deviceWs.close(4409, 'Replaced by newer connection'); } catch {}
          }
          this.deviceWs = ws;
          this.authenticated = true;

          ws.send(JSON.stringify({ t: 'auth.ok', presence: 'online', ts: Math.floor(Date.now() / 1000) }));
          this.broadcastToMobiles({
            t: 'presence',
            d: this.deviceId,
            status: 'online',
            ts: Math.floor(Date.now() / 1000),
          });
          return;
        }

        if (data.t === 'ping') {
          ws.send(JSON.stringify({ t: 'pong', ts: Math.floor(Date.now() / 1000) }));
          return;
        }
        this.broadcastToMobiles(data);
      } catch {}
    });

    ws.addEventListener('close', () => {
      clearTimeout(handshakeTimer);
      if (this.deviceWs === ws) {
        this.deviceWs = null;
        this.authenticated = false;
        this.broadcastToMobiles({
          t: 'presence',
          d: this.deviceId,
          status: 'offline',
          ts: Math.floor(Date.now() / 1000),
        });
      }
    });
  }

  private handleMobile(ws: WebSocket) {
    ws.accept();
    this.mobileSockets.add(ws);

    const isOnline = this.deviceWs !== null && this.authenticated;
    ws.send(JSON.stringify({
      t: 'presence',
      d: this.deviceId,
      status: isOnline ? 'online' : 'offline',
      ts: Math.floor(Date.now() / 1000),
    }));

    ws.addEventListener('message', (event) => {
      try {
        const data = JSON.parse(event.data as string);
        if (data.t === 'ping') {
          ws.send(JSON.stringify({ t: 'pong', ts: Math.floor(Date.now() / 1000) }));
          return;
        }
        // Only forward to a Mac that has proven its identity.
        if (this.deviceWs && this.authenticated) {
          this.deviceWs.send(JSON.stringify(data));
        } else {
          ws.send(JSON.stringify({
            t: 'error',
            code: 'MAC_OFFLINE',
            message: 'Target Mac is currently offline',
            d: this.deviceId,
            ts: Math.floor(Date.now() / 1000),
          }));
        }
      } catch {}
    });

    ws.addEventListener('close', () => {
      this.mobileSockets.delete(ws);
    });
  }

  private broadcastToMobiles(data: any) {
    const payload = JSON.stringify(data);
    for (const ws of this.mobileSockets) {
      try { ws.send(payload); } catch {}
    }
  }
}
