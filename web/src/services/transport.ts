/**
 * Distee Mobile Transport Client
 * Manages WebSocket sessions to the relay per Mac and handles message dispatch.
 */

import {
  getRelayUrl,
  getPairedMac,
  incrementMacSeq,
  updateMacLockTime,
  updateMacLastSeen,
  removePairedMac,
  getOrCreatePhoneKeys,
} from '../storage/storage';
import { sealEnvelope, verifyMacResult } from '../crypto/crypto';

export type DevicePresence = 'online' | 'offline' | 'connecting' | 'reconnecting' | 'failed';

export interface LockExecutionResult {
  success: boolean;
  status: string;
  mechanism: string;
  durationMs: number;
  message?: string;
}

export interface UnlockExecutionResult {
  success: boolean;
  status: string;
  mechanism: string;
  durationMs: number;
  message?: string;
}

interface PendingLock {
  resolve: (res: LockExecutionResult) => void;
  reject: (err: any) => void;
  timer: any;
}

interface PendingUnlock {
  resolve: (res: UnlockExecutionResult) => void;
  reject: (err: any) => void;
  timer: any;
}

export class MacTransport {
  public deviceId: string;
  public presence: DevicePresence = 'connecting';
  public onPresenceChange?: (status: DevicePresence) => void;

  private ws: WebSocket | null = null;
  private pingInterval: any = null;
  private reconnectTimer: any = null;
  private retryAttempt = 0;
  private closedExplicitly = false;
  private pendingLockResolvers = new Map<string, PendingLock>();
  private pendingUnlockResolvers = new Map<string, PendingUnlock>();

  constructor(deviceId: string) {
    this.deviceId = deviceId.toLowerCase();
  }

  public connect(): void {
    this.closedExplicitly = false;
    this.cleanup();

    const baseUrl = getRelayUrl();
    const wsUrl = `${baseUrl.replace(/\/+$/, '')}/ws/mobile/${this.deviceId}`;

    this.setPresence('connecting');

    try {
      this.ws = new WebSocket(wsUrl);

      this.ws.onopen = () => {
        this.retryAttempt = 0;
        this.startHeartbeat();
      };

      this.ws.onmessage = (event) => {
        this.handleMessage(event.data);
      };

      this.ws.onclose = () => {
        this.stopHeartbeat();
        // A command already sent has an unknown outcome once the socket drops; say so
        // instead of leaving the button spinning until the timeout.
        this.failPendingLocks('Connection lost before the Mac confirmed. The Mac may or may not have locked.');
        if (!this.closedExplicitly) {
          this.scheduleReconnect();
        } else {
          this.setPresence('offline');
        }
      };

      this.ws.onerror = () => {
        // onclose will fire after onerror and handle reconnection
      };
    } catch {
      this.setPresence('offline');
      this.scheduleReconnect();
    }
  }

  public disconnect(): void {
    this.closedExplicitly = true;
    this.cleanup();
    this.setPresence('offline');
  }

  /**
   * Called when the page returns to the foreground or the network comes back. Mobile browsers
   * suspend timers and silently drop sockets in the background, so a socket that is not
   * OPEN is replaced immediately instead of waiting for the backoff timer.
   */
  public reconnectIfNeeded(): void {
    if (this.closedExplicitly) return;
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    if (this.ws && this.ws.readyState === WebSocket.CONNECTING) return;
    this.retryAttempt = 0;
    this.connect();
  }

  private failPendingLocks(message: string): void {
    for (const [id, pending] of this.pendingLockResolvers) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
      this.pendingLockResolvers.delete(id);
    }
    for (const [id, pending] of this.pendingUnlockResolvers) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
      this.pendingUnlockResolvers.delete(id);
    }
  }

  private cleanup(): void {
    this.stopHeartbeat();
    this.failPendingLocks('Connection was reset before the Mac confirmed. The Mac may or may not have locked.');
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onclose = null;
      this.ws.onerror = null;
      try {
        this.ws.close();
      } catch {}
      this.ws = null;
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.pingInterval = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ t: 'ping', ts: Math.floor(Date.now() / 1000) }));
      }
    }, 25000);
  }

  private stopHeartbeat(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private scheduleReconnect(): void {
    this.retryAttempt++;
    this.setPresence(this.retryAttempt > 1 ? 'reconnecting' : 'offline');
    const delay = Math.min(1000 * Math.pow(1.5, this.retryAttempt), 15000);
    this.reconnectTimer = setTimeout(() => {
      if (!this.closedExplicitly) {
        this.connect();
      }
    }, delay);
  }

  private setPresence(status: DevicePresence): void {
    if (this.presence !== status) {
      this.presence = status;
      this.onPresenceChange?.(status);
    }
  }

  private handleMessage(raw: string): void {
    try {
      const data = JSON.parse(raw);

      // Presence updates from relay
      if (data.t === 'presence') {
        const online = data.status === 'online';
        if (online) updateMacLastSeen(this.deviceId);
        this.setPresence(online ? 'online' : 'offline');
        return;
      }

      // Lock response frames from Mac. Rejections are unsigned (they only ever make a
      // command fail, never succeed). Success and failure results must carry the Mac's
      // signature, because the relay is untrusted and could otherwise forge "locked".
      if (data.t === 'lock.ack' || data.t === 'lock.failed' || data.t === 'lock.rejected') {
        const pending = this.pendingLockResolvers.get(data.id);
        if (!pending) return;
        if (data.t === 'lock.rejected') {
          clearTimeout(pending.timer);
          this.pendingLockResolvers.delete(data.id);
          pending.resolve({
            success: false,
            status: 'rejected',
            mechanism: 'none',
            durationMs: 0,
            message: `Lock command rejected: ${data.reason || 'UNAUTHORIZED'}`,
          });
        } else {
          void this.settleSignedLockResult(data, pending);
        }
        return;
      }

      // Unlock response frames from Mac.
      if (data.t === 'unlock.ack' || data.t === 'unlock.failed' || data.t === 'unlock.rejected') {
        const pending = this.pendingUnlockResolvers.get(data.id);
        if (!pending) return;
        if (data.t === 'unlock.rejected') {
          clearTimeout(pending.timer);
          this.pendingUnlockResolvers.delete(data.id);
          pending.resolve({
            success: false,
            status: 'rejected',
            mechanism: 'none',
            durationMs: 0,
            message: `Unlock command rejected: ${data.reason || 'UNAUTHORIZED'}`,
          });
        } else {
          void this.settleSignedUnlockResult(data, pending);
        }
        return;
      }

      // Unpair confirmation: only a signed ack for the unpair we sent counts.
      if (data.t === 'unpair.ack') {
        void this.acceptUnpairAck(data);
        return;
      }

      if (data.t === 'unpair.rejected') {
        this.finishUnpair(false);
        return;
      }

      if (data.t === 'error' && data.code === 'MAC_OFFLINE') {
        this.setPresence('offline');
        // The relay did not deliver the frame, so we know the Mac did not lock because of it.
        this.failPendingLocks('The Mac is offline. The lock command was not delivered.');
        this.finishUnpair(false);
      }
    } catch {}
  }

  /**
   * Settles a pending lock from a `lock.ack` / `lock.failed` frame, but only after the
   * Mac's signature checks out. A frame that fails verification is dropped, so a forged
   * result leaves the command pending until the real answer or the timeout.
   */
  private async settleSignedLockResult(data: any, pending: PendingLock): Promise<void> {
    const mac = getPairedMac(this.deviceId);
    if (!mac) return;
    const valid = await verifyMacResult(mac.macSignPubKey, data, {
      deviceId: mac.deviceId,
      epoch: mac.epoch,
      id: data.id,
    });
    if (!valid) {
      console.warn('Ignored a lock result without a valid Mac signature');
      return;
    }
    // Another result for the same command may have settled it while we were verifying.
    if (this.pendingLockResolvers.get(data.id) !== pending) return;
    clearTimeout(pending.timer);
    this.pendingLockResolvers.delete(data.id);

    if (data.t === 'lock.ack') {
      updateMacLockTime(this.deviceId);
      pending.resolve({
        success: true,
        status: data.status || 'locked',
        mechanism: data.mechanism || 'cgevent',
        durationMs: data.durationMs || 0,
      });
    } else {
      pending.resolve({
        success: false,
        status: data.status || 'failed',
        mechanism: data.mechanism || 'none',
        durationMs: data.durationMs || 0,
        message: data.detail || 'Lock failed on Mac',
      });
    }
  }

  private async settleSignedUnlockResult(data: any, pending: PendingUnlock): Promise<void> {
    const mac = getPairedMac(this.deviceId);
    if (!mac) return;
    const valid = await verifyMacResult(mac.macSignPubKey, data, {
      deviceId: mac.deviceId,
      epoch: mac.epoch,
      id: data.id,
    });
    if (!valid) {
      console.warn('Ignored an unlock result without a valid Mac signature');
      return;
    }
    if (this.pendingUnlockResolvers.get(data.id) !== pending) return;
    clearTimeout(pending.timer);
    this.pendingUnlockResolvers.delete(data.id);

    if (data.t === 'unlock.ack') {
      pending.resolve({
        success: true,
        status: data.status || 'unlocked',
        mechanism: data.mechanism || 'cgevent',
        durationMs: data.durationMs || 0,
      });
    } else {
      pending.resolve({
        success: false,
        status: data.status || 'failed',
        mechanism: data.mechanism || 'none',
        durationMs: data.durationMs || 0,
        message: data.detail || 'Unlock failed on Mac',
      });
    }
  }

  private async acceptUnpairAck(data: any): Promise<void> {
    const expectedId = this.pendingUnpairId;
    const mac = getPairedMac(this.deviceId);
    if (!expectedId || !mac || data?.id !== expectedId) return;
    const valid = await verifyMacResult(mac.macSignPubKey, data, {
      deviceId: mac.deviceId,
      epoch: mac.epoch,
      id: expectedId,
    });
    if (!valid) {
      console.warn('Ignored an unpair acknowledgement without a valid Mac signature');
      return;
    }
    if (this.pendingUnpairId !== expectedId) return;
    this.finishUnpair(true);
  }

  /**
   * Dispatches a signed, encrypted remote lock command to the Mac.
   */
  public async sendLockCommand(timeoutMs = 12000): Promise<LockExecutionResult> {
    const mac = getPairedMac(this.deviceId);
    if (!mac) throw new Error('Mac is not paired');
    if (this.presence === 'offline') throw new Error('Mac is currently offline');

    const phoneKeys = await getOrCreatePhoneKeys();
    const seq = incrementMacSeq(this.deviceId);

    const payload = new TextEncoder().encode(JSON.stringify({ action: 'lock', requestedAt: Date.now() }));
    const envelope = await sealEnvelope(
      payload,
      'cmd.lock',
      mac.deviceId,
      mac.epoch,
      seq,
      mac.macEcdhPubKey,
      phoneKeys
    );

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingLockResolvers.delete(envelope.id);
        reject(new Error('Lock command timed out waiting for Mac confirmation'));
      }, timeoutMs);

      this.pendingLockResolvers.set(envelope.id, { resolve, reject, timer });

      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(envelope));
      } else {
        clearTimeout(timer);
        this.pendingLockResolvers.delete(envelope.id);
        reject(new Error('Relay connection is closed'));
      }
    });
  }

  /**
   * Dispatches a signed, encrypted remote unlock command to the Mac.
   */
  public async sendUnlockCommand(password: string, timeoutMs = 15000): Promise<UnlockExecutionResult> {
    const mac = getPairedMac(this.deviceId);
    if (!mac) throw new Error('Mac is not paired');
    if (this.presence === 'offline') throw new Error('Mac is currently offline');
    if (!password) throw new Error('Password cannot be empty');

    const phoneKeys = await getOrCreatePhoneKeys();
    const seq = incrementMacSeq(this.deviceId);

    const payload = new TextEncoder().encode(JSON.stringify({
      action: 'unlock',
      password,
      requestedAt: Date.now()
    }));
    const envelope = await sealEnvelope(
      payload,
      'cmd.unlock',
      mac.deviceId,
      mac.epoch,
      seq,
      mac.macEcdhPubKey,
      phoneKeys
    );

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingUnlockResolvers.delete(envelope.id);
        reject(new Error('Unlock command timed out waiting for Mac confirmation'));
      }, timeoutMs);

      this.pendingUnlockResolvers.set(envelope.id, { resolve, reject, timer });

      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(envelope));
      } else {
        clearTimeout(timer);
        this.pendingUnlockResolvers.delete(envelope.id);
        reject(new Error('Relay connection is closed'));
      }
    });
  }

  /**
   * Dispatches an authenticated unpair command to the Mac.
   */
  private pendingUnpair: ((acked: boolean) => void) | null = null;
  private pendingUnpairId: string | null = null;

  private finishUnpair(acked: boolean): void {
    const done = this.pendingUnpair;
    this.pendingUnpair = null;
    this.pendingUnpairId = null;
    done?.(acked);
  }

  /**
   * Sends a signed unpair command. Resolves true only if the Mac acknowledged it.
   * The local record is NOT removed here; the caller decides what to do on false.
   */
  public async sendUnpairCommand(timeoutMs = 6000): Promise<boolean> {
    const mac = getPairedMac(this.deviceId);
    if (!mac) return true;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || this.presence !== 'online') return false;

    const phoneKeys = await getOrCreatePhoneKeys();
    const seq = incrementMacSeq(this.deviceId);
    const payload = new TextEncoder().encode(JSON.stringify({ action: 'unpair', requestedAt: Date.now() }));
    const envelope = await sealEnvelope(
      payload,
      'cmd.unpair',
      mac.deviceId,
      mac.epoch,
      seq,
      mac.macEcdhPubKey,
      phoneKeys
    );

    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.pendingUnpair = null;
        this.pendingUnpairId = null;
        resolve(false);
      }, timeoutMs);
      this.pendingUnpairId = envelope.id;
      this.pendingUnpair = (acked) => {
        clearTimeout(timer);
        resolve(acked);
      };
      try {
        this.ws!.send(JSON.stringify(envelope));
      } catch {
        clearTimeout(timer);
        this.pendingUnpair = null;
        this.pendingUnpairId = null;
        resolve(false);
      }
    });
  }
}

/**
 * Manages active transport instances for all paired Macs.
 */
class TransportRegistry {
  private transports = new Map<string, MacTransport>();

  constructor() {
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') this.reconnectAll();
      });
    }
    if (typeof window !== 'undefined') {
      window.addEventListener('online', () => this.reconnectAll());
      window.addEventListener('pageshow', () => this.reconnectAll());
    }
  }

  private reconnectAll(): void {
    for (const t of this.transports.values()) {
      t.reconnectIfNeeded();
    }
  }

  public getOrCreate(deviceId: string): MacTransport {
    const id = deviceId.toLowerCase();
    if (!this.transports.has(id)) {
      const transport = new MacTransport(id);
      this.transports.set(id, transport);
    }
    return this.transports.get(id)!;
  }

  public remove(deviceId: string): void {
    const id = deviceId.toLowerCase();
    const existing = this.transports.get(id);
    if (existing) {
      existing.disconnect();
      this.transports.delete(id);
    }
  }

  public disconnectAll(): void {
    for (const t of this.transports.values()) {
      t.disconnect();
    }
    this.transports.clear();
  }
}

export const transports = new TransportRegistry();
