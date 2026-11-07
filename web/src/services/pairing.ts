/**
 * Distee Pairing Client Service
 * Orchestrates QR payload decoding, key derivation, and handshake exchange.
 */

import {
  base64UrlDecode,
  derivePairingKey,
  deriveConfirmationCode,
  encryptPairRequest,
  decryptAndVerifyPairAccept,
} from '../crypto/crypto';
import { getOrCreatePhoneKeys, savePairedMac, getRelayUrl, PairedMac } from '../storage/storage';

export interface QRPayload {
  v: number;
  deviceId: string;
  macSignPub: string;
  macEcdhPub: string;
  sessionId: string;
  psk: Uint8Array;
  expiresAt: number;
  name: string;
}

/**
 * Parses and validates a QR code string or URL.
 */
export function parseQRPayload(raw: string): QRPayload {
  let search = '';
  if (raw.includes('?')) {
    search = raw.substring(raw.indexOf('?'));
  } else if (raw.includes('=')) {
    search = `?${raw}`;
  } else {
    throw new Error('Invalid QR code: missing query parameters');
  }

  const params = new URLSearchParams(search);
  const v = parseInt(params.get('v') || '1', 10);
  const deviceId = params.get('d');
  const macSignPub = params.get('pk');
  const macEcdhPub = params.get('ek');
  const sessionId = params.get('sid');
  const k = params.get('k');
  const exp = parseInt(params.get('exp') || '0', 10);
  const name = params.get('n') || 'Mac';

  if (!deviceId || !macSignPub || !macEcdhPub || !sessionId || !k) {
    throw new Error('Malformed pairing QR payload: missing cryptographic parameters');
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (exp > 0 && exp < nowSeconds) {
    throw new Error('This QR code has expired. Please regenerate it on your Mac.');
  }

  return {
    v,
    deviceId: deviceId.toLowerCase(),
    macSignPub,
    macEcdhPub,
    sessionId,
    psk: base64UrlDecode(k),
    expiresAt: exp,
    name,
  };
}

/**
 * Resolves a 6-digit pairing code from the relay server.
 */
export async function resolvePairingCode(code: string): Promise<QRPayload> {
  const cleanCode = code.trim().replace(/[-\s]+/g, '');
  if (cleanCode.length !== 6) {
    throw new Error('Please enter a valid 6-digit code');
  }

  const relayWs = getRelayUrl();
  const httpBase = relayWs
    .replace(/^wss:\/\//i, 'https://')
    .replace(/^ws:\/\//i, 'http://');

  const res = await fetch(`${httpBase}/api/pair/resolve?code=${encodeURIComponent(cleanCode)}`);
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.message || 'Invalid or expired 6-digit code. Check your Mac screen.');
  }

  const data = await res.json();
  return {
    v: 1,
    deviceId: data.deviceId.toLowerCase(),
    macSignPub: data.pk,
    macEcdhPub: data.ek,
    sessionId: data.sid,
    psk: base64UrlDecode(data.k),
    expiresAt: data.exp,
    name: data.name || 'Mac',
  };
}

export interface PairingResult {
  mac: PairedMac;
  confCode: string;
}

/**
 * Executes the complete pairing handshake with the Mac via the relay.
 */
export async function executePairingHandshake(
  qr: QRPayload,
  phoneLabel = 'My Phone',
  onConfCodeReady?: (confCode: string) => void,
  timeoutMs = 30000
): Promise<PairingResult> {
  const phoneKeys = await getOrCreatePhoneKeys();
  const kp = await derivePairingKey(qr.psk, qr.sessionId);

  const confCode = await deriveConfirmationCode(
    qr.psk,
    qr.sessionId,
    phoneKeys.signPubRaw,
    phoneKeys.ecdhPubRaw
  );
  onConfCodeReady?.(confCode);

  const reqPayload = await encryptPairRequest(kp, qr.sessionId, qr.deviceId, {
    phoneSignPub: phoneKeys.signPubRaw,
    phoneEcdhPub: phoneKeys.ecdhPubRaw,
    label: phoneLabel,
    platform: navigator.userAgent.slice(0, 40),
  });

  const baseUrl = getRelayUrl();
  const wsUrl = `${baseUrl.replace(/\/+$/, '')}/ws/mobile/${qr.deviceId}`;

  return new Promise((resolve, reject) => {
    let ws: WebSocket | null = null;
    const timer = setTimeout(() => {
      if (ws) {
        try { ws.close(); } catch {}
      }
      reject(new Error('Pairing timed out. Ensure the Mac is online and approve the prompt.'));
    }, timeoutMs);

    try {
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        // Send pair.request frame
        const frame = {
          v: 1,
          t: 'pair.request',
          d: qr.deviceId,
          sid: qr.sessionId,
          req: reqPayload.req,
          n: reqPayload.nonce,
          ts: Math.floor(Date.now() / 1000),
        };
        ws?.send(JSON.stringify(frame));
      };

      ws.onmessage = async (event) => {
        try {
          const data = JSON.parse(event.data);

          if (data.t === 'pair.reject') {
            clearTimeout(timer);
            ws?.close();
            const reason = data.reason || 'DENIED';
            if (reason === 'ALREADY_PAIRED') {
              reject(new Error('This Mac is already paired with an authorized device. Unpair it first.'));
            } else if (reason === 'SESSION_EXPIRED' || reason === 'INVALID_SESSION') {
              reject(new Error('Pairing session expired or already used. Generate a new QR code on your Mac.'));
            } else if (reason === 'DENIED') {
              reject(new Error('Pairing was denied on the Mac.'));
            } else if (reason === 'PAIRING_IN_PROGRESS') {
              reject(new Error('Another pairing request is already waiting for approval on the Mac. Try again in a moment.'));
            } else if (reason === 'BAD_CRYPTO' || reason === 'MALFORMED_REQUEST') {
              reject(new Error('The Mac could not read the pairing request. Generate a new QR code and try again.'));
            } else {
              reject(new Error(`Pairing rejected: ${reason}`));
            }
            return;
          }

          if (data.t === 'pair.accept') {
            clearTimeout(timer);
            ws?.close();

            const acceptData = await decryptAndVerifyPairAccept(
              kp,
              qr.sessionId,
              qr.deviceId,
              data.res,
              data.n,
              qr.macSignPub,
              phoneKeys.signPubRaw
            );

            const pairedMac: PairedMac = {
              deviceId: qr.deviceId,
              name: qr.name,
              macSignPubKey: qr.macSignPub,
              macEcdhPubKey: qr.macEcdhPub,
              epoch: acceptData.epoch,
              pairedAt: Date.now(),
              nextSeq: 1,
            };

            savePairedMac(pairedMac);
            resolve({ mac: pairedMac, confCode });
          }
        } catch (err: any) {
          clearTimeout(timer);
          ws?.close();
          reject(err);
        }
      };

      ws.onerror = () => {
        // Continue waiting until timeout or rejection
      };
    } catch (err) {
      clearTimeout(timer);
      reject(err);
    }
  });
}

