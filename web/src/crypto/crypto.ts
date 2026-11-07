/**
 * Distee WebCrypto Implementation
 * Native browser P-256 ECDSA, ECDH, HKDF-SHA256, and AES-256-GCM.
 */

// Base64URL encoding/decoding without padding
export function base64UrlEncode(buffer: ArrayBuffer | Uint8Array): string {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

export function base64UrlDecode(str: string): Uint8Array {
  let base64 = str.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4 !== 0) {
    base64 += '=';
  }
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// RFC 4648 lowercase base32 (without padding)
const BASE32_ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';
export function base32Encode(buffer: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let output = '';

  for (let i = 0; i < buffer.length; i++) {
    value = (value << 8) | buffer[i];
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }

  if (bits > 0) {
    output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  }

  return output;
}

export interface PhoneKeyPair {
  signKeyPair: CryptoKeyPair;
  ecdhKeyPair: CryptoKeyPair;
  signPubRaw: string; // base64url
  ecdhPubRaw: string; // base64url
}

export function assertSecureContext(): void {
  if (typeof window !== 'undefined' && (!window.crypto || !window.crypto.subtle)) {
    throw new Error(
      'Web Cryptography is unavailable in insecure contexts (plain HTTP). Access Distee via HTTPS so your mobile browser enables crypto keys and camera access.'
    );
  }
}

/**
 * Generates phone P-256 signing and key agreement keypairs.
 */
export async function generatePhoneKeys(): Promise<PhoneKeyPair> {
  assertSecureContext();
  // extractable=false protects the private keys; the public halves remain exportable.
  const signKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign', 'verify']
  );

  const ecdhKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    ['deriveKey', 'deriveBits']
  );

  const signPubRawBuffer = await crypto.subtle.exportKey('raw', signKeyPair.publicKey);
  const ecdhPubRawBuffer = await crypto.subtle.exportKey('raw', ecdhKeyPair.publicKey);

  return {
    signKeyPair,
    ecdhKeyPair,
    signPubRaw: base64UrlEncode(signPubRawBuffer),
    ecdhPubRaw: base64UrlEncode(ecdhPubRawBuffer),
  };
}

/**
 * Derives the symmetric pairing key: Kp = HKDF(psk, salt=sid, info="distee/pair/v1")
 */
export async function derivePairingKey(psk: Uint8Array, sid: string): Promise<CryptoKey> {
  const sidBytes = base64UrlDecode(sid);
  const pskKey = await crypto.subtle.importKey(
    'raw',
    psk as any,
    { name: 'HKDF' },
    false,
    ['deriveKey']
  );

  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: sidBytes as any,
      info: new TextEncoder().encode('distee/pair/v1') as any,
    },
    pskKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

/**
 * Derives the 6-digit confirmation code displayed on both screens.
 */
export async function deriveConfirmationCode(
  psk: Uint8Array,
  sid: string,
  phoneSignPub: string,
  phoneEcdhPub: string
): Promise<string> {
  const sidBytes = base64UrlDecode(sid);
  const signBytes = base64UrlDecode(phoneSignPub);
  const ecdhBytes = base64UrlDecode(phoneEcdhPub);

  const totalLength = psk.length + sidBytes.length + signBytes.length + ecdhBytes.length;
  const transcript = new Uint8Array(totalLength);
  let offset = 0;
  transcript.set(psk, offset); offset += psk.length;
  transcript.set(sidBytes, offset); offset += sidBytes.length;
  transcript.set(signBytes, offset); offset += signBytes.length;
  transcript.set(ecdhBytes, offset);

  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', transcript as any));
  const num = ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) >>> 0;
  const code = num % 1_000_000;
  return code.toString().padStart(6, '0');
}

/**
 * Encrypts pair.request payload using AES-256-GCM with Kp.
 */
export async function encryptPairRequest(
  kp: CryptoKey,
  sid: string,
  deviceId: string,
  payload: {
    phoneSignPub: string;
    phoneEcdhPub: string;
    label: string;
    platform: string;
  }
): Promise<{ req: string; nonce: string }> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const aad = new TextEncoder().encode(`${sid}${deviceId}pair.request`);

  const ciphertextWithTag = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as any, additionalData: aad as any },
    kp,
    plaintext as any
  );

  return {
    req: base64UrlEncode(ciphertextWithTag),
    nonce: base64UrlEncode(nonce),
  };
}

/**
 * Decrypts pair.accept response and verifies the Mac's ECDSA proof signature.
 */
export async function decryptAndVerifyPairAccept(
  kp: CryptoKey,
  sid: string,
  deviceId: string,
  resBase64: string,
  nonceBase64: string,
  macSignPubBase64: string,
  phoneSignPubBase64: string
): Promise<{ epoch: number; macSignPub: string; macEcdhPub: string }> {
  const ciphertextWithTag = base64UrlDecode(resBase64);
  const nonce = base64UrlDecode(nonceBase64);
  const aad = new TextEncoder().encode(`${sid}${deviceId}pair.accept`);

  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce as any, additionalData: aad as any },
    kp,
    ciphertextWithTag as any
  );

  const data = JSON.parse(new TextDecoder().decode(decrypted));
  const { epoch, macSignPub, macEcdhPub, proof } = data;

  // Verify Mac ECDSA signature
  const proofBytes = base64UrlDecode(proof);
  const proofInput = new TextEncoder().encode(
    `distee-pair-accept\n${sid}\n${epoch}\n${phoneSignPubBase64}\n${macSignPub}`
  );

  // CryptoKit rawRepresentation is 64 bytes (x||y) without the 0x04 uncompressed prefix.
  // WebCrypto 'raw' format requires the 65-byte uncompressed form (0x04||x||y).
  const macSignPubBytes = base64UrlDecode(macSignPubBase64);
  const macSignPubUncompressed = macSignPubBytes.length === 64
    ? (() => { const b = new Uint8Array(65); b[0] = 0x04; b.set(macSignPubBytes, 1); return b; })()
    : macSignPubBytes;

  const macKey = await crypto.subtle.importKey(
    'raw',
    macSignPubUncompressed as any,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify']
  );

  // Note: proof signature from CryptoKit is DER representation.
  // Standard WebCrypto verify expects IEEE P1363 (r || s, 64 bytes).
  const p1363Sig = derToP1363(proofBytes);
  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    macKey,
    p1363Sig as any,
    proofInput as any
  );

  if (!valid) {
    throw new Error('Mac proof signature verification failed');
  }

  return { epoch, macSignPub, macEcdhPub };
}

/**
 * Verifies the Mac's signature on a result frame (`lock.ack`, `lock.failed`, `unpair.ack`).
 *
 * The relay is untrusted and could otherwise forge a "locked" confirmation, so a result is
 * only believed when it is signed by the Mac key learned at pairing, names the expected
 * device and epoch, and answers exactly the command we sent.
 *
 * The signed layout must match `EnvelopeCoding.ackSigningInput` in the Swift agent:
 *   "distee/v1/ack\n{t}\n{d}\n{e}\n{id}\n{status}\n{ts}"
 */
export async function verifyMacResult(
  macSignPubBase64: string,
  frame: any,
  expected: { deviceId: string; epoch: number; id: string }
): Promise<boolean> {
  try {
    if (
      typeof frame?.t !== 'string' ||
      typeof frame.d !== 'string' ||
      typeof frame.status !== 'string' ||
      typeof frame.sig !== 'string' ||
      typeof frame.ts !== 'number' ||
      typeof frame.e !== 'number'
    ) {
      return false;
    }
    if (
      frame.d.toLowerCase() !== expected.deviceId.toLowerCase() ||
      frame.e !== expected.epoch ||
      frame.id !== expected.id
    ) {
      return false;
    }

    const input = new TextEncoder().encode(
      `distee/v1/ack\n${frame.t}\n${frame.d}\n${frame.e}\n${frame.id}\n${frame.status}\n${frame.ts}`
    );

    // CryptoKit's rawRepresentation is 64 bytes (x||y); WebCrypto wants 0x04||x||y.
    const keyBytes = base64UrlDecode(macSignPubBase64);
    const uncompressed = keyBytes.length === 64
      ? (() => { const b = new Uint8Array(65); b[0] = 0x04; b.set(keyBytes, 1); return b; })()
      : keyBytes;
    const key = await crypto.subtle.importKey(
      'raw',
      uncompressed as any,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify']
    );

    return await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      derToP1363(base64UrlDecode(frame.sig)) as any,
      input as any
    );
  } catch {
    return false;
  }
}

/**
 * Converts ASN.1 DER ECDSA signature to IEEE P1363 (r || s, 64 bytes) for WebCrypto.
 */
function derToP1363(der: Uint8Array): Uint8Array {
  if (der.length === 64) return der; // already raw r||s
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error('Invalid DER sequence');
  if (der[offset] & 0x80) offset += (der[offset] & 0x7f) + 1; else offset++; // skip sequence length

  // Parse r
  if (der[offset++] !== 0x02) throw new Error('Invalid DER integer for r');
  const rLen = der[offset++];
  let r = der.slice(offset, offset + rLen);
  offset += rLen;
  while (r.length > 32 && r[0] === 0x00) r = r.slice(1);
  const rPadded = new Uint8Array(32);
  rPadded.set(r, 32 - r.length);

  // Parse s
  if (der[offset++] !== 0x02) throw new Error('Invalid DER integer for s');
  const sLen = der[offset++];
  let s = der.slice(offset, offset + sLen);
  while (s.length > 32 && s[0] === 0x00) s = s.slice(1);
  const sPadded = new Uint8Array(32);
  sPadded.set(s, 32 - s.length);

  const raw = new Uint8Array(64);
  raw.set(rPadded, 0);
  raw.set(sPadded, 32);
  return raw;
}

/**
 * Converts IEEE P1363 (64 bytes) to ASN.1 DER ECDSA signature for Swift/CryptoKit.
 */
export function p1363ToDer(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) return raw;
  let r = raw.slice(0, 32);
  let s = raw.slice(32, 64);

  // Strip leading zeros but keep single 0x00 if highest bit is set
  while (r.length > 1 && r[0] === 0x00 && (r[1] & 0x80) === 0) r = r.slice(1);
  if ((r[0] & 0x80) !== 0) {
    const nr = new Uint8Array(r.length + 1);
    nr[0] = 0x00;
    nr.set(r, 1);
    r = nr;
  }

  while (s.length > 1 && s[0] === 0x00 && (s[1] & 0x80) === 0) s = s.slice(1);
  if ((s[0] & 0x80) !== 0) {
    const ns = new Uint8Array(s.length + 1);
    ns[0] = 0x00;
    ns.set(s, 1);
    s = ns;
  }

  const seqLen = 2 + r.length + 2 + s.length;
  const der = new Uint8Array(2 + seqLen);
  der[0] = 0x30;
  der[1] = seqLen;
  der[2] = 0x02;
  der[3] = r.length;
  der.set(r, 4);
  const sOffset = 4 + r.length;
  der[sOffset] = 0x02;
  der[sOffset + 1] = s.length;
  der.set(s, sOffset + 2);

  return der;
}

/**
 * Seals an end-to-end encrypted and signed command envelope.
 */
export async function sealEnvelope(
  plaintext: Uint8Array,
  type: string,
  deviceId: string,
  epoch: number,
  seq: number,
  recipientEcdhPubBase64: string,
  signerKeyPair: PhoneKeyPair
): Promise<any> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const nonceBase64 = base64UrlEncode(nonce);
  const messageId = generateULID();
  const timestamp = Math.floor(Date.now() / 1000);

  // 1. Ephemeral ECDH key agreement
  const ephemeralKey = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveKey', 'deriveBits']
  );
  const ephemeralPubRaw = await crypto.subtle.exportKey('raw', ephemeralKey.publicKey);
  const ephBase64 = base64UrlEncode(ephemeralPubRaw);

  // CryptoKit rawRepresentation is 64 bytes (x||y); WebCrypto 'raw' needs 65-byte uncompressed (0x04||x||y).
  const recipientEcdhBytes = base64UrlDecode(recipientEcdhPubBase64);
  const recipientEcdhUncompressed = recipientEcdhBytes.length === 64
    ? (() => { const b = new Uint8Array(65); b[0] = 0x04; b.set(recipientEcdhBytes, 1); return b; })()
    : recipientEcdhBytes;

  const recipientKey = await crypto.subtle.importKey(
    'raw',
    recipientEcdhUncompressed as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    []
  );

  const sharedSecretBits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: recipientKey },
    ephemeralKey.privateKey,
    256
  );

  // 2. HKDF derived AES-GCM key
  const sharedKeyMaterial = await crypto.subtle.importKey(
    'raw',
    sharedSecretBits,
    { name: 'HKDF' },
    false,
    ['deriveKey']
  );

  const info = new TextEncoder().encode(`distee/v1/enc\n${deviceId}\n${epoch}`);
  const aesKey = await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: nonce as any, info: info as any },
    sharedKeyMaterial,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );

  // 3. Header & AAD
  const headerText = `distee/v1\n${type}\n${deviceId}\n${epoch}\n${messageId}\n${seq}\n${timestamp}\n${nonceBase64}`;
  const headerBytes = new TextEncoder().encode(headerText);

  // 4. AES-GCM Seal
  const ciphertextWithTag = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as any, additionalData: headerBytes as any },
    aesKey,
    plaintext as any
  );
  const ctBase64 = base64UrlEncode(ciphertextWithTag);

  // 5. ECDSA Sign over canonical input: header || "\n" || eph || "\n" || SHA-256(ciphertext)
  const ctHash = await crypto.subtle.digest('SHA-256', ciphertextWithTag);
  const ephBytes = new TextEncoder().encode(ephBase64);
  const newline = new Uint8Array([0x0a]);

  const signingInput = new Uint8Array(
    headerBytes.length + 1 + ephBytes.length + 1 + ctHash.byteLength
  );
  let off = 0;
  signingInput.set(headerBytes, off); off += headerBytes.length;
  signingInput.set(newline, off); off += 1;
  signingInput.set(ephBytes, off); off += ephBytes.length;
  signingInput.set(newline, off); off += 1;
  signingInput.set(new Uint8Array(ctHash), off);

  const p1363Signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    signerKeyPair.signKeyPair.privateKey,
    signingInput as any
  );
  const derSig = p1363ToDer(new Uint8Array(p1363Signature));
  const sigBase64 = base64UrlEncode(derSig);

  return {
    v: 1,
    t: type,
    d: deviceId,
    e: epoch,
    id: messageId,
    seq,
    ts: timestamp,
    n: nonceBase64,
    eph: ephBase64,
    ct: ctBase64,
    sig: sigBase64,
  };
}

// Generate Crockford base32 ULID
export function generateULID(): string {
  const time = Date.now();
  const timeChars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  let t = time;
  let str = '';
  for (let i = 0; i < 10; i++) {
    str = timeChars[t % 32] + str;
    t = Math.floor(t / 32);
  }
  const randomChars = crypto.getRandomValues(new Uint8Array(16));
  for (let i = 0; i < 16; i++) {
    str += timeChars[randomChars[i] % 32];
  }
  return str;
}
