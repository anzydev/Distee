/**
 * Distee Persistent Storage Manager
 * Stores paired Macs and device key material in browser storage.
 */

import { generatePhoneKeys, PhoneKeyPair, assertSecureContext } from '../crypto/crypto';

export interface PairedMac {
  deviceId: string;
  name: string;
  macSignPubKey: string;
  macEcdhPubKey: string;
  epoch: number;
  pairedAt: number;
  lastLockAt?: number;
  lastSeenAt?: number;
  nextSeq: number;
}

const STORAGE_KEY_MACS = 'distee_paired_macs';
const STORAGE_KEY_RELAY = 'distee_relay_url';
const DB_NAME = 'distee_db';
const KEY_STORE = 'keys';

/**
 * Returns the configured relay WebSocket URL.
 */
export function getRelayUrl(): string {
  const custom = localStorage.getItem(STORAGE_KEY_RELAY);
  if (custom) return custom;
  
  const host = window.location.hostname || 'localhost';
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  
  // When served over HTTPS (Cloudflare Tunnel, Workers, Pages) or behind a reverse proxy,
  // the WebSocket relay is accessed on the same public origin without an explicit port.
  if (protocol === 'wss:' || !window.location.port || window.location.port === '443' || window.location.port === '80') {
    return `${protocol}//${host}`;
  }
  
  // In local development: if port is 5173 (Vite), point to relay on 8799. Otherwise use current port.
  const port = window.location.port === '5173' ? ':8799' : `:${window.location.port || '8799'}`;
  return `${protocol}//${host}${port}`;
}

export function setRelayUrl(url: string): void {
  localStorage.setItem(STORAGE_KEY_RELAY, url);
}

/**
 * Loads all paired Macs from local storage.
 */
export function getPairedMacs(): PairedMac[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY_MACS);
    if (!raw) return [];
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

export function getPairedMac(deviceId: string): PairedMac | undefined {
  return getPairedMacs().find((m) => m.deviceId.toLowerCase() === deviceId.toLowerCase());
}

export function savePairedMac(mac: PairedMac): void {
  const macs = getPairedMacs();
  const index = macs.findIndex((m) => m.deviceId.toLowerCase() === mac.deviceId.toLowerCase());
  if (index >= 0) {
    macs[index] = mac;
  } else {
    macs.push(mac);
  }
  localStorage.setItem(STORAGE_KEY_MACS, JSON.stringify(macs));
}

export function removePairedMac(deviceId: string): void {
  const macs = getPairedMacs().filter((m) => m.deviceId.toLowerCase() !== deviceId.toLowerCase());
  localStorage.setItem(STORAGE_KEY_MACS, JSON.stringify(macs));
  setMacUnlockPassword(deviceId, null);
}

const STORAGE_PREFIX_UNLOCK_PWD = 'distee_pwd_';

export function getMacUnlockPassword(deviceId: string): string | null {
  try {
    return localStorage.getItem(`${STORAGE_PREFIX_UNLOCK_PWD}${deviceId.toLowerCase()}`);
  } catch {
    return null;
  }
}

export function setMacUnlockPassword(deviceId: string, password: string | null): void {
  try {
    const key = `${STORAGE_PREFIX_UNLOCK_PWD}${deviceId.toLowerCase()}`;
    if (password) {
      localStorage.setItem(key, password);
    } else {
      localStorage.removeItem(key);
    }
  } catch {}
}

export function hasMacUnlockPassword(deviceId: string): boolean {
  return Boolean(getMacUnlockPassword(deviceId));
}

export function updateMacLockTime(deviceId: string): number | undefined {
  const mac = getPairedMac(deviceId);
  if (!mac) return undefined;
  mac.lastLockAt = Date.now();
  savePairedMac(mac);
  return mac.lastLockAt;
}

/**
 * Records the last time the relay reported this Mac as online ("last successful connection").
 */
export function updateMacLastSeen(deviceId: string): number | undefined {
  const mac = getPairedMac(deviceId);
  if (!mac) return undefined;
  mac.lastSeenAt = Date.now();
  savePairedMac(mac);
  return mac.lastSeenAt;
}

export function incrementMacSeq(deviceId: string): number {
  const mac = getPairedMac(deviceId);
  if (!mac) return 1;
  const current = mac.nextSeq || 1;
  mac.nextSeq = current + 1;
  savePairedMac(mac);
  return current;
}

// In-memory key cache for the active session
let cachedPhoneKeys: PhoneKeyPair | null = null;

/**
 * Loads or generates the phone's persistent P-256 keys.
 *
 * The private keys are generated non-extractable and stored in IndexedDB as CryptoKey
 * objects (structured clone), so their raw bytes are never readable by page scripts.
 */
export async function getOrCreatePhoneKeys(): Promise<PhoneKeyPair> {
  assertSecureContext();
  if (cachedPhoneKeys) return cachedPhoneKeys;

  // Try loading from IndexedDB
  try {
    const db = await openDB();
    const stored = await getKeyFromDB(db, 'phone_keys');
    if (stored) {
      cachedPhoneKeys = stored;
      return stored;
    }
  } catch (err) {
    console.warn('IndexedDB unavailable, falling back to memory/session:', err);
  }

  // Generate fresh keys
  const keys = await generatePhoneKeys();
  cachedPhoneKeys = keys;

  try {
    const db = await openDB();
    await saveKeyToDB(db, 'phone_keys', keys);
  } catch {}

  return keys;
}

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(KEY_STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function getKeyFromDB(db: IDBDatabase, key: string): Promise<PhoneKeyPair | null> {
  return new Promise((resolve) => {
    const tx = db.transaction(KEY_STORE, 'readonly');
    const store = tx.objectStore(KEY_STORE);
    const req = store.get(key);
    req.onsuccess = async () => {
      const stored = req.result;
      if (!stored) { resolve(null); return; }

      // Current format: CryptoKey objects stored directly.
      if (stored.signKeyPair && stored.ecdhKeyPair && stored.signPubRaw && stored.ecdhPubRaw) {
        resolve({
          signKeyPair: stored.signKeyPair,
          ecdhKeyPair: stored.ecdhKeyPair,
          signPubRaw: stored.signPubRaw,
          ecdhPubRaw: stored.ecdhPubRaw,
        });
        return;
      }

      // Legacy format: exportable JWKs. Re-import as non-extractable and migrate the record
      // so the private key material no longer sits in storage in readable form.
      try {
        const signPrivateKey = await crypto.subtle.importKey('jwk', stored.signPrivJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
        const signPublicKey = await crypto.subtle.importKey('jwk', stored.signPubJwk, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify']);
        const ecdhPrivateKey = await crypto.subtle.importKey('jwk', stored.ecdhPrivJwk, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveKey', 'deriveBits']);
        const ecdhPublicKey = await crypto.subtle.importKey('jwk', stored.ecdhPubJwk, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
        const migrated: PhoneKeyPair = {
          signKeyPair: { privateKey: signPrivateKey, publicKey: signPublicKey },
          ecdhKeyPair: { privateKey: ecdhPrivateKey, publicKey: ecdhPublicKey },
          signPubRaw: stored.signPubRaw,
          ecdhPubRaw: stored.ecdhPubRaw,
        };
        try {
          await saveKeyToDB(db, key, migrated);
        } catch {
          // Keep working with the in-memory keys; the legacy record stays until next load.
        }
        resolve(migrated);
      } catch {
        resolve(null);
      }
    };
    req.onerror = () => resolve(null);
  });
}

function saveKeyToDB(db: IDBDatabase, key: string, value: PhoneKeyPair): Promise<void> {
  return new Promise((resolve, reject) => {
    try {
      const serializable = {
        signKeyPair: value.signKeyPair,
        ecdhKeyPair: value.ecdhKeyPair,
        signPubRaw: value.signPubRaw,
        ecdhPubRaw: value.ecdhPubRaw,
      };
      const tx = db.transaction(KEY_STORE, 'readwrite');
      const store = tx.objectStore(KEY_STORE);
      const req = store.put(serializable, key);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error);
    } catch (err) {
      reject(err);
    }
  });
}
