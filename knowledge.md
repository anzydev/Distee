# Distee — Complete System Knowledge Base (`knowledge.md`)

This document provides a comprehensive technical overview of **Distee**, explaining its architecture, cryptographic protocols, inter-device communications, operating system interactions, and runtime behavior.

---

## 1. High-Level Architecture Overview

Distee is a zero-infrastructure-cost (₹0 / $0.00) remote screen-locking and unlocking system that bridges a native macOS background application and a mobile Progressive Web App (PWA) across heterogeneous networks (e.g., Cellular 5G/4G $\leftrightarrow$ Campus/Home Wi-Fi).

```
┌─────────────────────────────────┐           ┌────────────────────────────────┐           ┌─────────────────────────────────┐
│         Mobile Web App          │           │      Zero-Knowledge Relay      │           │       macOS Native Agent        │
│             (PWA)               │   WSS     │     (Node.js + Cloudflare)     │   WSS     │          (Distee.app)           │
│  React · TypeScript · WebCrypto │ ◄───────► │    Room: /ws/mobile/:id        │ ◄───────► │  Swift · CryptoKit · CoreGraphic│
│  (Holds Phone Private Keys)     │  TLS 443  │    Room: /ws/device/:id        │  Port 8799│  (Holds Mac Private Keys)       │
└─────────────────────────────────┘           └────────────────────────────────┘           └─────────────────────────────────┘
                 │                                                                                          │
                 └────────────────── End-to-End Encrypted Tunnel ───────────────────────────────────────────┘
                                   (P-256 ECDH + AES-256-GCM + ECDSA)
```

### The Three Core Pillars

1. **Native macOS Agent (`macos/`)**:
   - A lightweight menu bar application (`LSUIElement = true`) written in Swift using native macOS frameworks (`CryptoKit`, `CoreGraphics`, `Network.framework`).
   - Runs silently in the background, consuming under 12 MB of RAM and 0.0% idle CPU.
   - Listens for authenticated and encrypted commands to physically lock or unlock the macOS session.
   - Avoids macOS Keychain APIs to prevent security popups; credentials are stored in POSIX-permissioned private user storage (`0700`/`0600`).

2. **Zero-Knowledge Relay (`relay/` + `bin/cloudflared`)**:
   - A minimalist Node.js WebSocket router that pairs a Mac connection (`/ws/device/:id`) with one or more mobile connections (`/ws/mobile/:id`).
   - Acts strictly as an opaque pipe: passes encrypted JSON envelopes without being able to read or tamper with them.
   - Uses an ephemeral `cloudflared` tunnel (`https://*.trycloudflare.com`) to expose the local relay over public HTTPS/WSS without opening router ports or buying domains.

3. **Mobile Web App (`web/`)**:
   - A responsive React + Vite PWA optimized for mobile browsers (iOS Safari, Android Chrome).
   - Generates and stores its own P-256 keypairs directly in browser storage (`IndexedDB`) using the hardware-backed Web Cryptography API (`crypto.subtle`).
   - Scans the Mac's QR code using the device camera (`jsQR`) to establish the cryptographic trust relationship.

---

## 2. Cryptographic Identity & Trust Model

Distee implements a decentralized, zero-trust model: **No accounts, no emails, no passwords stored in the cloud, and no central authentication servers.**

### 2.1 Key Types & Curves

Both the Mac and the mobile device generate standard **NIST P-256 (secp256r1)** elliptic curve keypairs:
- **Signing Keypair (`ECDSA` with `SHA-256`)**: Used for mutual authentication, challenge signing, and command integrity verification.
- **Key Agreement Keypair (`ECDH`)**: Used for Ephemeral-Static ECIES payload encryption.

### 2.2 Device Identifier Derivation

Every Mac derives a deterministic, permanent 16-character identifier from its public signing key:

$$\text{DeviceId} = \text{Base32}(\text{SHA-256}(\text{PublicKey}_{\text{Mac}}^{\text{raw}}))[0\dots 15]$$

- Example: `k4x9m2p7q8v1w3z5`
- This ensures that a device ID is cryptographically anchored to its public key and cannot be spoofed without the private key.

### 2.3 Secret Storage Architecture

- **macOS Storage**: Private POSIX file-backed storage at:  
  `~/Library/Application Support/com.distee.agent/secrets/`
  - Directory permissions: `0700` (`rwx------`)
  - File permissions: `0600` (`rw-------`)
  - *Design Decision*: Completely eliminates macOS Keychain password prompts caused by unsigned or ad-hoc signed CLI/Swift builds.
- **Mobile Storage**:
  - `IndexedDB` stores the non-extractable `CryptoKey` objects via Structured Clone.
  - Browser scripts and malicious extensions cannot export the raw private key bytes.

---

## 3. Physical Proximity QR Pairing Protocol

Pairing bridges the air-gap between the Mac and the phone using visual optical physical proximity.

```
Mac (Distee.app)                                  Mobile Phone (Browser PWA)
      │                                                       │
      ├───── 1. Generates 256-bit ephemeral PSK ──────────────┤
      ├───── 2. Displays QR code containing: ────────────────┤
      │         • Web URL (HTTPS)                             │
      │         • Session ID (UUID)                           │
      │         • Device ID                                   │
      │         • Mac Public Signing Key                      │
      │         • Mac Public ECDH Key                         │
      │         • Epoch counter                               │
      │         • 256-bit PSK                                 │
      │                                                       │
      │                     (Camera Scan)                     │
      │ ◄─────────────────────────────────────────────────────┤
      │                                                       │
      │ ◄─── 3. Phone sends `pair.request` via Relay ─────────┤
      │         (Encrypted under PSK using AES-256-GCM)       │
      │                                                       │
      ├───── 4. Both derive identical 6-digit SAS code ───────┤
      │         Code = HKDF-SHA256(PSK, "distee-confirm")[0..5]│
      │                                                       │
      ├───── 5. Mac user clicks "Allow" if codes match ───────┤
      │                                                       │
      ├───── 6. Mac sends `pair.accept` ─────────────────────►│
      │         (Signed by Mac, includes epoch & timestamp)   │
      │                                                       │
   [PAIRED]                                                [PAIRED]
```

### Key Security Properties of Pairing:
1. **120-Second Expiration**: Pairing sessions self-destruct after 2 minutes if unconfirmed.
2. **Short Authentication String (SAS)**: A deterministic 6-digit code shown on both screens prevents relay/man-in-the-middle attacks.
3. **Single Authorized Device Constraint**: A Mac accepts exactly one authorized phone at a time. Second pairing attempts are immediately rejected (`ALREADY_PAIRED`) until the current device explicitly unpairs.
4. **Monotonic Epoch**: Every unpair or state reset increments the `epoch` counter. Old commands signed under previous epochs are permanently rejected.

---

## 4. Cross-Network Communication Protocol

Once paired, the phone and Mac communicate via WebSocket through the Zero-Knowledge Relay over Port 443 / 8799.

### 4.1 Relay Authentication Challenge

When the Mac connects to the relay (`/ws/device/:deviceId`), the relay issues a cryptographic challenge:
1. Relay sends: `{ t: "hello", challenge: "<32-byte-base64url>" }`
2. Mac proves ownership by signing:
   $$\text{Signature} = \text{Sign}_{\text{Mac}}(\text{"distee-auth-v1"} \parallel \text{challenge} \parallel \text{deviceId} \parallel \text{epoch})$$
3. Relay verifies the signature against the public key and checks that `Base32(SHA256(pk)) == deviceId`.
4. Only an authenticated Mac is allowed to claim the device room.

### 4.2 End-to-End Encrypted Command Envelope

Every command (e.g., `cmd.lock`, `cmd.unlock`, `cmd.unpair`) is packaged into a sealed cryptographic envelope:

```json
{
  "v": 1,
  "t": "cmd.lock",
  "d": "k4x9m2p7q8v1w3z5",
  "e": 1,
  "id": "01JCVEXAMPLEULID0000000000",
  "seq": 42,
  "ts": 1731000000,
  "n": "<12-byte-base64url-nonce>",
  "eph": "<65-byte-phone-ephemeral-ecdh-pubkey>",
  "ct": "<aes-256-gcm-ciphertext-and-tag>",
  "sig": "<phone-ecdsa-signature-over-canonical-header>"
}
```

### 4.3 Five Layers of Command Defense
1. **Target Verification (`d`)**: Mac discards frames addressed to any other device ID.
2. **Epoch Matching (`e`)**: Commands must match the Mac's current active pairing epoch.
3. **Replay Protection (`seq` + `id`)**:
   - `seq`: Strictly increasing 64-bit integer. Any frame with `seq <= lastSequence` is rejected.
   - `id`: Monotonic ULID checked against an in-memory 500-entry ring buffer.
4. **Freshness Window (`ts`)**: Commands older than 120 seconds are discarded to prevent store-and-forward replays.
5. **Authenticated ECDSA Signature (`sig`)**: Covers all header fields. Tampering with any field invalidates the signature before decryption is even attempted.

---

## 5. OS-Level Execution: Screen Locking & Unlocking

### 5.1 Remote Screen Lock (`cmd.lock`)
Locking is an **unprivileged system operation** on macOS. Distee uses a dual-mechanism engine:

1. **Primary Mechanism (`CGEvent` ⌃⌘Q)**:
   - Synthesizes the native macOS Lock Screen keyboard shortcut (`Control + Command + Q`) via CoreGraphics:
     ```swift
     let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x0C, keyDown: true)
     down.flags = [.maskControl, .maskCommand]
     down.post(tap: .cghidEventTap)
     ```
   - Requires macOS Accessibility permission (`AXIsProcessTrusted`).
2. **Fallback Mechanism (`pmset displaysleepnow`)**:
   - When Accessibility is unavailable, triggers `/usr/bin/pmset displaysleepnow`.
   - On macOS default settings (where password is required immediately upon display sleep), this safely and instantly locks the session without extra privileges.
3. **State Verification**:
   - Distee queries `CGSessionCopyCurrentDictionary()` and asserts that `CGSSessionScreenIsLocked == true` before sending back `lock.ack`.

---

### 5.2 Remote Screen Unlock (`cmd.unlock`)
Unlocking is a **credential-gated security boundary**. macOS does not offer a public unlock API. Distee implements secure remote unlock through encrypted credential dispatch:

1. **Client-Side Secret Storage**:
   - The user inputs their Mac login password on the phone once.
   - The password is saved locally in phone storage (protected by the phone's biometrics / PIN).
2. **Sealed Transmission**:
   - Tapping "Unlock" encrypts the password into an ephemeral ECIES envelope (`action: "unlock", password: "..."`).
   - The relay server never sees the plaintext password.
3. **Display Wake & Input Injection**:
   - The Mac agent receives and decrypts the password in volatile memory.
   - **Wake Display**: Executes `/usr/bin/caffeinate -u -t 2` and posts a HID event to turn on monitors and display the login prompt.
   - **Clear Screensaver**: Posts an Escape key (`0x35`) to focus the password field.
   - **Synthesize Keystrokes**: Injects the password characters one-by-one with 12ms inter-key delays using `keyboardSetUnicodeString`:
     ```swift
     var utf16Char = [char]
     down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
     down.post(tap: .cghidEventTap)
     ```
   - **Trigger Login**: Posts a Return key (`0x24`).
   - **Fallback Automation**: If CoreGraphics tap is blocked by the window server, falls back to `System Events` AppleScript.
4. **Unlock Verification**:
   - Polls `CGSessionCopyCurrentDictionary()` every 100ms.
   - When `CGSSessionScreenIsLocked` changes to `false` (or disappears), it confirms the session is unlocked and immediately clears the plaintext password from memory.
   - Emits a signed `unlock.ack` back to the phone.

---

## 6. Project Directory Reference

```
Distee/
├── bin/
│   └── cloudflared                 # Pre-compiled tunnel binary (zero-cost HTTPS edge)
├── macos/
│   ├── Package.swift               # Swift Package Manager manifest
│   ├── Scripts/
│   │   └── build-app.sh            # Production compilation & ad-hoc code signing
│   ├── Sources/
│   │   ├── Distee/                 # App lifecycle, Menu bar icon & SwiftUI UI
│   │   └── DisteeCore/             # Core business & security logic
│   │       ├── Core/Models/        # Envelope, DeviceIdentifier, ULID models
│   │       ├── Services/
│   │       │   ├── BackgroundService.swift   # Main coordinator & WebSocket handler
│   │       │   ├── ConnectionManager.swift   # WebSocket lifecycle & reconnection ladder
│   │       │   ├── EnvelopeCrypto.swift      # ECIES (P-256 + AES-GCM) engine
│   │       │   ├── KeychainManager.swift     # 0600 file-backed secret storage
│   │       │   ├── MacLockManager.swift      # CoreGraphics ⌃⌘Q & pmset locker
│   │       │   ├── MacUnlockManager.swift    # Display wake & synthetic unlocker
│   │       │   ├── PairingManager.swift      # Ephemeral QR pairing state machine
│   │       │   ├── ScreenStateProvider.swift # CGSession lock state inspection
│   │       │   └── SecurityManager.swift     # CryptoKit key management
│   └── Tests/
│       └── DisteeTests/            # 53 automated tests covering all modules
├── relay/
│   ├── package.json                # WebSocket server dependencies (ws)
│   ├── server.js                   # Node.js zero-knowledge relay router
│   └── worker.ts                   # Optional Cloudflare Worker implementation
├── web/
│   ├── index.html                  # Mobile PWA entrypoint
│   ├── package.json                # Vite + React + Lucide dependencies
│   ├── src/
│   │   ├── App.tsx                 # Main mobile container & pairing overlay
│   │   ├── components/
│   │   │   ├── MacCard.tsx         # Dual Lock/Unlock card & password modal
│   │   │   └── PairingModal.tsx    # Camera QR scanner (jsQR)
│   │   ├── crypto/
│   │   │   └── crypto.ts           # WebCrypto P-256, ECDH, AES-GCM engine
│   │   ├── services/
│   │   │   └── transport.ts        # Mobile WebSocket transport & state machine
│   │   └── storage/
│   │       └── storage.ts          # IndexedDB key storage & local password cache
├── start.sh                        # One-click startup (Relay + Tunnel + Mac Agent)
├── stop.sh                         # Clean process teardown
└── .gitignore                      # Git exclusion rules
```

---

## 7. Execution & Operating Reference

### Starting the System
```bash
./start.sh
open macos/build/Distee.app
```
1. `start.sh` compiles the web frontend into `web/dist/`.
2. Launches `relay/server.js` on port `8799`.
3. Launches `bin/cloudflared` to generate a live `https://*.trycloudflare.com` URL (saved to `~/.distee_web_url`).
4. `Distee.app` starts in the menu bar and connects to the local relay.

### Running Test Verification
The project includes an automated native test suite executing 53 end-to-end tests:
```bash
cd macos && swift run distee-tests
```
*Result:* `PASS — 53 tests, 1 skipped`

### Stopping the System
```bash
./stop.sh
```
Kills `Distee.app`, `cloudflared`, and the Node.js relay process, and cleans temporary log files.

