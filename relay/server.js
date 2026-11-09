/**
 * Distee Zero-Cost WebSocket Relay Server
 * 
 * Routes end-to-end encrypted envelopes between paired Macs and Mobile clients.
 * Zero-knowledge: the relay never holds private keys, PSKs, or decrypted messages.
 */

const http = require('http');
const { WebSocketServer, WebSocket } = require('ws');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.PORT || '8799', 10);
const HOST = process.env.HOST || '0.0.0.0';
const WEB_DIST = path.resolve(__dirname, '../web/dist');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

// In-memory room registry: deviceId -> { deviceSocket, mobileSockets: Set }
const rooms = new Map();

// Active 6-digit pairing codes: code (string) -> pairing session metadata
const pairingCodes = new Map();
const MAX_PAIRING_CODES = 500;

// Rate limiting for 6-digit code resolution: IP -> { count, resetAt }
const resolveAttempts = new Map();

// Password-gated "Lock All" for the hackathon test panel. The default password lives here
// only (never in the web bundle); rotate it by editing this line or by setting
// DISTEE_TEST_PASSWORD in the environment.
const TEST_PASSWORD = process.env.DISTEE_TEST_PASSWORD || '9fh40f(&G(oub)';
const TEST_MAX_ATTEMPTS = 10;
const TEST_WINDOW_MS = 60000;

// Failed test-panel attempts: IP -> { count, resetAt }
const testAttempts = new Map();

function isRateLimited(ip) {
  const now = Date.now();
  const entry = resolveAttempts.get(ip);
  if (entry) {
    if (now > entry.resetAt) {
      resolveAttempts.delete(ip);
      return false;
    }
    return entry.count >= 15;
  }
  return false;
}

function recordFailedAttempt(ip) {
  const now = Date.now();
  const entry = resolveAttempts.get(ip);
  if (!entry || now > entry.resetAt) {
    resolveAttempts.set(ip, { count: 1, resetAt: now + 60000 });
  } else {
    entry.count++;
  }
}

function cleanExpiredPairingCodes() {
  const now = Date.now();
  for (const [code, entry] of pairingCodes.entries()) {
    if (entry.expiresAt && now > entry.expiresAt) {
      pairingCodes.delete(code);
    }
  }
  for (const [ip, entry] of resolveAttempts.entries()) {
    if (now > entry.resetAt) {
      resolveAttempts.delete(ip);
    }
  }
  for (const [ip, entry] of testAttempts.entries()) {
    if (now > entry.resetAt) {
      testAttempts.delete(ip);
    }
  }
}
setInterval(cleanExpiredPairingCodes, 10000);

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'SAMEORIGIN',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
};

function isTestRateLimited(ip) {
  const now = Date.now();
  const entry = testAttempts.get(ip);
  if (!entry) return false;
  if (now > entry.resetAt) {
    testAttempts.delete(ip);
    return false;
  }
  return entry.count >= TEST_MAX_ATTEMPTS;
}

function recordTestFailure(ip) {
  const now = Date.now();
  const entry = testAttempts.get(ip);
  if (!entry || now > entry.resetAt) {
    testAttempts.set(ip, { count: 1, resetAt: now + TEST_WINDOW_MS });
  } else {
    entry.count++;
  }
}

function passwordMatches(candidate) {
  if (typeof candidate !== 'string') return false;
  const given = Buffer.from(candidate, 'utf8');
  const expected = Buffer.from(TEST_PASSWORD, 'utf8');
  return given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(JSON.stringify(payload));
}

function readJsonBody(req, res, limit, done) {
  let body = '';
  let size = 0;
  let finished = false;

  req.on('data', (chunk) => {
    if (finished) return;
    size += chunk.length;
    if (size > limit) {
      finished = true;
      sendJson(res, 413, { status: 'error', message: 'Payload too large' });
      req.destroy();
      return;
    }
    body += chunk;
  });

  req.on('end', () => {
    if (finished) return;
    finished = true;
    try {
      done(JSON.parse(body || '{}'));
    } catch {
      sendJson(res, 400, { status: 'error', message: 'Invalid JSON body' });
    }
  });
}

const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
function base32Lower(buf) {
  let bits = 0, value = 0, out = '';
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

// Verifies the Mac's challenge response: the public key must hash to the device id
// and the signature must cover the relay's challenge.
function verifyDeviceAuth(deviceId, challenge, data) {
  try {
    if (typeof data.pk !== 'string' || typeof data.sig !== 'string' || typeof data.e !== 'number') return false;
    const pub = Buffer.from(data.pk, 'base64url');
    if (pub.length !== 65 || pub[0] !== 0x04) return false;
    const derived = base32Lower(crypto.createHash('sha256').update(pub).digest()).slice(0, 16);
    if (derived !== deviceId) return false;
    const key = crypto.createPublicKey({
      key: {
        kty: 'EC',
        crv: 'P-256',
        x: pub.subarray(1, 33).toString('base64url'),
        y: pub.subarray(33, 65).toString('base64url'),
      },
      format: 'jwk',
    });
    const input = Buffer.from(`distee-auth-v1\n${challenge}\n${deviceId}\n${data.e}`);
    return crypto.verify('sha256', input, { key, dsaEncoding: 'der' }, Buffer.from(data.sig, 'base64url'));
  } catch {
    return false;
  }
}

function getOrCreateRoom(deviceId) {
  if (!rooms.has(deviceId)) {
    rooms.set(deviceId, {
      deviceId,
      deviceSocket: null,
      mobileSockets: new Set(),
      pendingChallenge: null,
      deviceEpoch: 0,
      authenticated: false,
      pending: 0,
    });
  }
  return rooms.get(deviceId);
}

// Frees a room once no Mac and no phone are attached, so the registry cannot grow unbounded.
function pruneRoom(room) {
  if (!room.deviceSocket && room.mobileSockets.size === 0 && room.pending === 0) {
    rooms.delete(room.deviceId);
  }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const clientIp = req.headers['x-forwarded-for']
    ? req.headers['x-forwarded-for'].split(',')[0].trim()
    : (req.socket.remoteAddress || '127.0.0.1');

  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      ...SECURITY_HEADERS,
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end();
    return;
  }

  // Register 6-digit code (Mac -> Relay)
  if (req.method === 'POST' && url.pathname === '/api/pair/code') {
    if (pairingCodes.size >= MAX_PAIRING_CODES) {
      res.writeHead(503, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ status: 'error', message: 'Relay pairing registry is full. Try again shortly.' }));
      return;
    }

    let body = '';
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 32768) {
        res.writeHead(413, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'error', message: 'Payload too large' }));
        req.destroy();
        return;
      }
      body += chunk;
    });

    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        if (!data.code || !data.deviceId || !data.sid) {
          res.writeHead(400, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
          res.end(JSON.stringify({ status: 'error', message: 'Missing required fields' }));
          return;
        }
        const code = String(data.code).trim().replace(/[-\s]+/g, '');
        if (!/^[0-9]{6}$/.test(code)) {
          res.writeHead(400, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
          res.end(JSON.stringify({ status: 'error', message: 'Pairing code must be 6 numeric digits' }));
          return;
        }
        pairingCodes.set(code, {
          code,
          deviceId: data.deviceId,
          sid: data.sid,
          pk: data.pk,
          ek: data.ek,
          k: data.k,
          exp: data.exp || Math.floor((Date.now() + 120000) / 1000),
          name: data.name || 'Mac',
          expiresAt: Date.now() + 125000,
        });
        res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'ok', code }));
      } catch (err) {
        res.writeHead(400, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'error', message: err.message }));
      }
    });
    return;
  }

  // Resolve 6-digit code (Mobile -> Relay) with brute-force rate-limiting
  if (req.method === 'GET' && url.pathname === '/api/pair/resolve') {
    if (isRateLimited(clientIp)) {
      res.writeHead(429, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ status: 'error', message: 'Too many attempts. Please wait 1 minute.' }));
      return;
    }

    const code = (url.searchParams.get('code') || '').trim().replace(/[-\s]+/g, '');
    const entry = pairingCodes.get(code);
    if (!entry || (entry.expiresAt && Date.now() > entry.expiresAt)) {
      recordFailedAttempt(clientIp);
      res.writeHead(404, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ status: 'error', message: 'Invalid or expired 6-digit code' }));
      return;
    }

    resolveAttempts.delete(clientIp);
    res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify({
      status: 'ok',
      code: entry.code,
      deviceId: entry.deviceId,
      sid: entry.sid,
      pk: entry.pk,
      ek: entry.ek,
      k: entry.k,
      exp: entry.exp,
      name: entry.name,
    }));
    return;
  }

  // --- Hackathon test panel -------------------------------------------------------------
  // Password-only login used by the bottom-left "Test" control in the web app.
  if (req.method === 'POST' && url.pathname === '/api/test/auth') {
    if (isTestRateLimited(clientIp)) {
      sendJson(res, 429, { status: 'error', message: 'Too many attempts. Wait a minute and try again.' });
      return;
    }
    readJsonBody(req, res, 8192, (data) => {
      if (!passwordMatches(data.password)) {
        recordTestFailure(clientIp);
        sendJson(res, 401, { status: 'error', message: 'Incorrect test password' });
        return;
      }
      testAttempts.delete(clientIp);
      sendJson(res, 200, { status: 'ok' });
    });
    return;
  }

  // Locks every Mac currently authenticated with the relay. The Mac agent handles this
  // frame without requiring a pairing record, which is what makes judge testing possible.
  if (req.method === 'POST' && url.pathname === '/api/test/lock-all') {
    if (isTestRateLimited(clientIp)) {
      sendJson(res, 429, { status: 'error', message: 'Too many attempts. Wait a minute and try again.' });
      return;
    }
    readJsonBody(req, res, 8192, (data) => {
      if (!passwordMatches(data.password)) {
        recordTestFailure(clientIp);
        sendJson(res, 401, { status: 'error', message: 'Incorrect test password' });
        return;
      }
      testAttempts.delete(clientIp);

      const ts = Math.floor(Date.now() / 1000);
      let sent = 0;
      for (const room of rooms.values()) {
        const socket = room.deviceSocket;
        if (socket && room.authenticated && socket.readyState === WebSocket.OPEN) {
          try {
            socket.send(JSON.stringify({ t: 'test.lock', d: room.deviceId, ts }));
            sent += 1;
          } catch {}
        }
      }
      console.log(`[Relay] Test lock-all sent to ${sent} Mac(s)`);
      sendJson(res, 200, { status: 'ok', sent });
    });
    return;
  }

  if (url.pathname === '/health') {
    res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify({
      status: 'ok',
      service: 'distee-relay',
      activeRooms: rooms.size,
      activePairingCodes: pairingCodes.size,
      timestamp: Date.now(),
    }));
    return;
  }

  // Serve static web app from web/dist (SPA fallback to index.html)
  if (fs.existsSync(WEB_DIST)) {
    let decodedPath = url.pathname;
    try {
      decodedPath = decodeURIComponent(url.pathname);
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Bad Request');
      return;
    }
    let filePath = path.join(WEB_DIST, decodedPath);
    if (!filePath.startsWith(WEB_DIST + path.sep) && filePath !== WEB_DIST) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Forbidden');
      return;
    }
    if (url.pathname === '/' || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      filePath = path.join(WEB_DIST, 'index.html');
    }
    if (fs.existsSync(filePath)) {
      const ext = path.extname(filePath);
      const mime = MIME_TYPES[ext] || 'application/octet-stream';
      res.writeHead(200, {
        ...SECURITY_HEADERS,
        'Content-Type': mime,
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': ext === '.html' || ext === '.json' ? 'no-cache' : 'public, max-age=3600',
      });
      return fs.createReadStream(filePath).pipe(res);
    }
  }

  res.writeHead(404, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

const wss = new WebSocketServer({ server, maxPayload: 64 * 1024 });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  // Match /ws/device/:deviceId or /ws/mobile/:deviceId
  const deviceMatch = pathname.match(/^\/ws\/device\/([a-z0-9]{16})$/i);
  const mobileMatch = pathname.match(/^\/ws\/mobile\/([a-z0-9]{16})$/i);

  if (deviceMatch) {
    handleDeviceConnection(ws, deviceMatch[1].toLowerCase());
  } else if (mobileMatch) {
    handleMobileConnection(ws, mobileMatch[1].toLowerCase());
  } else {
    ws.close(4404, 'Invalid WebSocket route. Use /ws/device/:id or /ws/mobile/:id');
  }
});

function handleDeviceConnection(ws, deviceId) {
  const room = getOrCreateRoom(deviceId);

  // Registered first so the count is already decremented when the main close handler prunes.
  room.pending++;
  ws.once('close', () => { room.pending--; });

  const challenge = crypto.randomBytes(32).toString('base64url');
  let authenticated = false;
  let pending = { ws, challenge };

  // The new socket only replaces the current Mac after it proves it owns the device key.
  ws.once('close', () => { pending = null; });

  // Drop sockets that never complete the challenge-response.
  const handshakeTimer = setTimeout(() => {
    if (!authenticated) ws.close(4408, 'AUTH_TIMEOUT');
  }, 15000);
  ws.once('close', () => clearTimeout(handshakeTimer));

  // Step 1: Send hello with challenge
  ws.send(JSON.stringify({
    t: 'hello',
    challenge,
    d: deviceId,
    ts: Math.floor(Date.now() / 1000),
  }));

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message.toString());

      // Step 2: Handle authentication frame
      if (!authenticated) {
        if (data.t !== 'auth' || !pending || !verifyDeviceAuth(deviceId, pending.challenge, data)) {
          ws.send(JSON.stringify({ t: 'error', reason: 'BAD_SIGNATURE' }));
          ws.close(4403, 'BAD_SIGNATURE');
          return;
        }
        authenticated = true;
        pending = null;

        if (room.deviceSocket && room.deviceSocket !== ws && room.deviceSocket.readyState === WebSocket.OPEN) {
          room.deviceSocket.close(4409, 'Replaced by newer connection');
        }
        room.deviceSocket = ws;
        room.authenticated = true;
        room.deviceEpoch = data.e || 1;
        room.pendingChallenge = null;

        ws.send(JSON.stringify({
          t: 'auth.ok',
          presence: 'online',
          ts: Math.floor(Date.now() / 1000),
        }));

        // Notify mobile clients that Mac is online
        broadcastToMobiles(room, {
          t: 'presence',
          d: deviceId,
          status: 'online',
          ts: Math.floor(Date.now() / 1000),
        });

        console.log(`[Relay] Mac ${deviceId} authenticated (epoch ${room.deviceEpoch})`);
        return;
      }

      // Step 3: Handle heartbeats
      if (data.t === 'ping') {
        ws.send(JSON.stringify({ t: 'pong', ts: Math.floor(Date.now() / 1000) }));
        return;
      }

      // Step 3.5: Handle 6-digit pairing code registration
      if (data.t === 'pair.code_register' && data.code) {
        const code = String(data.code).trim().replace(/[-\s]+/g, '');
        pairingCodes.set(code, {
          code,
          deviceId: deviceId,
          sid: data.sid,
          pk: data.pk,
          ek: data.ek,
          k: data.k,
          exp: data.exp || Math.floor((Date.now() + 120000) / 1000),
          name: data.name || 'Mac',
          expiresAt: Date.now() + 125000,
        });
        console.log(`[Relay] Registered 6-digit code ${code} for Mac ${deviceId}`);
        return;
      }

      if (data.t === 'pair.code_clear' && data.code) {
        const code = String(data.code).trim().replace(/[-\s]+/g, '');
        pairingCodes.delete(code);
        console.log(`[Relay] Cleared 6-digit code ${code}`);
        return;
      }

      // Step 4: Route outbound messages from Mac to mobile clients
      // (e.g. pair.accept, pair.reject, lock.ack, unpair.ack)
      broadcastToMobiles(room, data);
    } catch (err) {
      console.error(`[Relay] Invalid JSON from Mac ${deviceId}:`, err.message);
    }
  });

  ws.on('close', (code, reason) => {
    if (room.deviceSocket === ws) {
      room.deviceSocket = null;
      room.authenticated = false;
      broadcastToMobiles(room, {
        t: 'presence',
        d: deviceId,
        status: 'offline',
        ts: Math.floor(Date.now() / 1000),
      });
      console.log(`[Relay] Mac ${deviceId} disconnected (${code})`);
    }
    pruneRoom(room);
  });

  ws.on('error', (err) => {
    console.error(`[Relay] Mac ${deviceId} socket error:`, err.message);
  });
}

function handleMobileConnection(ws, deviceId) {
  const room = getOrCreateRoom(deviceId);
  if (room.mobileSockets.size >= 10) {
    ws.close(4429, 'Room mobile limit reached');
    return;
  }
  room.mobileSockets.add(ws);

  const isMacOnline = room.deviceSocket && room.deviceSocket.readyState === WebSocket.OPEN && room.authenticated;

  // Inform mobile of current Mac presence immediately
  ws.send(JSON.stringify({
    t: 'presence',
    d: deviceId,
    status: isMacOnline ? 'online' : 'offline',
    ts: Math.floor(Date.now() / 1000),
  }));

  console.log(`[Relay] Mobile connected to room ${deviceId} (Mac is ${isMacOnline ? 'online' : 'offline'})`);

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message.toString());

      if (data.t === 'ping') {
        ws.send(JSON.stringify({ t: 'pong', ts: Math.floor(Date.now() / 1000) }));
        return;
      }

      // Test frames may only originate from this relay's own admin endpoint. Without this
      // check, anyone who knows a device id could lock a Mac with no pairing at all.
      if (typeof data.t === 'string' && data.t.startsWith('test.')) {
        ws.send(JSON.stringify({
          t: 'error',
          code: 'FORBIDDEN',
          message: 'Test frames are relay-only',
          d: deviceId,
          ts: Math.floor(Date.now() / 1000),
        }));
        return;
      }

      // Forward mobile command/request directly to Mac
      if (room.deviceSocket && room.deviceSocket.readyState === WebSocket.OPEN) {
        room.deviceSocket.send(JSON.stringify(data));
      } else {
        ws.send(JSON.stringify({
          t: 'error',
          code: 'MAC_OFFLINE',
          message: 'Target Mac is currently offline',
          d: deviceId,
          ts: Math.floor(Date.now() / 1000),
        }));
      }
    } catch (err) {
      console.error(`[Relay] Invalid JSON from Mobile for ${deviceId}:`, err.message);
    }
  });

  ws.on('close', () => {
    room.mobileSockets.delete(ws);
    console.log(`[Relay] Mobile disconnected from room ${deviceId}`);
    pruneRoom(room);
  });

  ws.on('error', (err) => {
    console.error(`[Relay] Mobile socket error for ${deviceId}:`, err.message);
  });
}

function broadcastToMobiles(room, data) {
  const payload = JSON.stringify(data);
  for (const client of room.mobileSockets) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(payload);
    }
  }
}

server.listen(PORT, HOST, () => {
  console.log(`===============================================`);
  console.log(`  Distee Relay Server running on ws://${HOST}:${PORT}`);
  console.log(`  Mac Endpoint:    ws://localhost:${PORT}/ws/device/:deviceId`);
  console.log(`  Mobile Endpoint: ws://localhost:${PORT}/ws/mobile/:deviceId`);
  console.log(`===============================================`);
});

