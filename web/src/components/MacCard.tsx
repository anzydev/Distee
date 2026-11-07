import React, { useState, useEffect, useRef } from 'react';
import { Lock, Unlock, CheckCircle2, AlertCircle, Loader2, Laptop, MoreVertical, Trash2, KeyRound } from 'lucide-react';
import {
  PairedMac,
  getMacUnlockPassword,
  setMacUnlockPassword,
  hasMacUnlockPassword,
} from '../storage/storage';
import { transports, DevicePresence, LockExecutionResult, UnlockExecutionResult } from '../services/transport';

interface MacCardProps {
  mac: PairedMac;
  onUnpair: (deviceId: string) => void | Promise<void>;
}

export const MacCard: React.FC<MacCardProps> = ({ mac, onUnpair }) => {
  const [presence, setPresence] = useState<DevicePresence>('connecting');
  const [locking, setLocking] = useState(false);
  const [unlocking, setUnlocking] = useState(false);
  const [lockResult, setLockResult] = useState<LockExecutionResult | null>(null);
  const [unlockResult, setUnlockResult] = useState<UnlockExecutionResult | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [showMenu, setShowMenu] = useState(false);
  const [lastLockAt, setLastLockAt] = useState<number | undefined>(mac.lastLockAt);
  const [lastSeenAt, setLastSeenAt] = useState<number | undefined>(mac.lastSeenAt);

  // Password modal states
  const [showPasswordModal, setShowPasswordModal] = useState(false);
  const [passwordInput, setPasswordInput] = useState('');
  const [rememberPassword, setRememberPassword] = useState(true);
  const [savedPasswordExists, setSavedPasswordExists] = useState(() => hasMacUnlockPassword(mac.deviceId));

  const menuRef = useRef<HTMLDivElement | null>(null);

  // Close menu on outside click
  useEffect(() => {
    if (!showMenu) return;
    const handleOutside = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setShowMenu(false);
      }
    };
    document.addEventListener('mousedown', handleOutside);
    return () => document.removeEventListener('mousedown', handleOutside);
  }, [showMenu]);

  useEffect(() => {
    const transport = transports.getOrCreate(mac.deviceId);
    setPresence(transport.presence);

    transport.onPresenceChange = (status) => {
      setPresence(status);
      if (status === 'online') setLastSeenAt(Date.now());
    };
    if (transport.presence === 'online') setLastSeenAt(Date.now());

    transport.connect();

    return () => {
      // Don't disconnect immediately so other views share the connection
    };
  }, [mac.deviceId]);

  const handleLock = async () => {
    if (locking || unlocking || presence === 'offline') return;

    setLocking(true);
    setErrorMessage(null);
    setLockResult(null);
    setUnlockResult(null);

    try {
      const transport = transports.getOrCreate(mac.deviceId);
      const result = await transport.sendLockCommand(12000);
      setLockResult(result);
      if (result.success) {
        setLastLockAt(Date.now());
      } else {
        setErrorMessage(result.message || 'Screen lock failed on Mac');
      }
    } catch (err: any) {
      setErrorMessage(err.message || 'Failed to send lock command');
    } finally {
      setLocking(false);
    }
  };

  const handleUnlockClick = () => {
    if (locking || unlocking || presence === 'offline') return;

    const saved = getMacUnlockPassword(mac.deviceId);
    if (saved) {
      void executeUnlock(saved);
    } else {
      setPasswordInput('');
      setRememberPassword(true);
      setShowPasswordModal(true);
    }
  };

  const executeUnlock = async (password: string) => {
    if (!password) {
      setErrorMessage('Please enter your Mac password to unlock.');
      return;
    }

    setUnlocking(true);
    setErrorMessage(null);
    setLockResult(null);
    setUnlockResult(null);

    try {
      const transport = transports.getOrCreate(mac.deviceId);
      const result = await transport.sendUnlockCommand(password, 15000);
      setUnlockResult(result);
      if (result.success) {
        setShowPasswordModal(false);
        setPasswordInput('');
      } else {
        setErrorMessage(result.message || 'Screen unlock failed on Mac');
      }
    } catch (err: any) {
      setErrorMessage(err.message || 'Failed to send unlock command');
    } finally {
      setUnlocking(false);
    }
  };

  const handleModalSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!passwordInput) return;

    if (rememberPassword) {
      setMacUnlockPassword(mac.deviceId, passwordInput);
      setSavedPasswordExists(true);
    }
    void executeUnlock(passwordInput);
  };

  const handleClearSavedPassword = () => {
    setMacUnlockPassword(mac.deviceId, null);
    setSavedPasswordExists(false);
    setShowMenu(false);
  };

  const formatTime = (ts?: number) => {
    if (!ts) return 'Never';
    const diff = Math.floor((Date.now() - ts) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return new Date(ts).toLocaleDateString();
  };

  const getPresenceBadge = () => {
    switch (presence) {
      case 'online':
        return (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '4px 10px', borderRadius: '9999px', fontSize: '12px', fontWeight: 600, background: 'rgba(34, 197, 94, 0.15)', color: '#4ade80' }}>
            <span style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#22c55e' }} />
            Online
          </span>
        );
      case 'connecting':
      case 'reconnecting':
        return (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '4px 10px', borderRadius: '9999px', fontSize: '12px', fontWeight: 600, background: 'rgba(234, 179, 8, 0.15)', color: '#facc15' }}>
            <span style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#eab308' }} />
            Connecting
          </span>
        );
      case 'offline':
      default:
        return (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '4px 10px', borderRadius: '9999px', fontSize: '12px', fontWeight: 600, background: 'rgba(148, 163, 184, 0.15)', color: '#94a3b8' }}>
            <span style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#64748b' }} />
            Offline
          </span>
        );
    }
  };

  return (
    <div style={{
      background: 'rgba(15, 23, 42, 0.85)',
      borderRadius: '20px',
      border: '1px solid rgba(255, 255, 255, 0.08)',
      padding: '20px',
      boxShadow: '0 10px 25px -5px rgba(0, 0, 0, 0.4)',
      position: 'relative',
      overflow: 'hidden'
    }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '14px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <div style={{
            width: '44px',
            height: '44px',
            borderRadius: '12px',
            background: 'rgba(99, 102, 241, 0.15)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: '#818cf8'
          }}>
            <Laptop size={24} />
          </div>
          <div>
            <div style={{ fontSize: '18px', fontWeight: 600, color: '#f8fafc' }}>
              {mac.name || 'Mac'}
            </div>
            <div style={{ fontSize: '12px', fontFamily: 'monospace', color: '#94a3b8' }}>
              {mac.deviceId}
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          {getPresenceBadge()}
          <button
            onClick={() => setShowMenu(!showMenu)}
            style={{
              background: 'transparent',
              border: 'none',
              color: '#94a3b8',
              padding: '6px',
              cursor: 'pointer',
              borderRadius: '8px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center'
            }}
          >
            <MoreVertical size={18} />
          </button>
        </div>
      </div>

      {/* Menu dropdown */}
      {showMenu && (
        <div ref={menuRef} style={{
          position: 'absolute',
          top: '64px',
          right: '20px',
          background: '#1e293b',
          borderRadius: '12px',
          border: '1px solid rgba(255, 255, 255, 0.1)',
          padding: '6px',
          zIndex: 20,
          boxShadow: '0 10px 20px rgba(0,0,0,0.5)',
          minWidth: '180px'
        }}>
          {savedPasswordExists ? (
            <button
              onClick={handleClearSavedPassword}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                width: '100%',
                background: 'transparent',
                border: 'none',
                padding: '8px 12px',
                fontSize: '13px',
                color: '#e2e8f0',
                cursor: 'pointer',
                borderRadius: '6px',
                textAlign: 'left'
              }}
            >
              <KeyRound size={15} color="#94a3b8" />
              Clear Saved Password
            </button>
          ) : (
            <button
              onClick={() => {
                setShowMenu(false);
                setPasswordInput('');
                setShowPasswordModal(true);
              }}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                width: '100%',
                background: 'transparent',
                border: 'none',
                padding: '8px 12px',
                fontSize: '13px',
                color: '#e2e8f0',
                cursor: 'pointer',
                borderRadius: '6px',
                textAlign: 'left'
              }}
            >
              <KeyRound size={15} color="#94a3b8" />
              Set Unlock Password
            </button>
          )}

          <div style={{ height: '1px', background: 'rgba(255,255,255,0.08)', margin: '4px 0' }} />

          <button
            onClick={() => {
              setShowMenu(false);
              if (confirm(`Unpair ${mac.name}? You will need to scan a new QR code on the Mac to control it again.`)) {
                onUnpair(mac.deviceId);
              }
            }}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '8px',
              width: '100%',
              background: 'transparent',
              border: 'none',
              padding: '8px 12px',
              fontSize: '13px',
              color: '#ef4444',
              cursor: 'pointer',
              borderRadius: '6px',
              textAlign: 'left'
            }}
          >
            <Trash2 size={15} />
            Unpair Mac
          </button>
        </div>
      )}

      {/* Info Rows */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: '8px',
        padding: '12px',
        background: 'rgba(0, 0, 0, 0.25)',
        borderRadius: '12px',
        marginBottom: '18px',
        fontSize: '13px'
      }}>
        <div>
          <div style={{ color: '#64748b', fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Last Lock</div>
          <div style={{ color: '#e2e8f0', fontWeight: 500, marginTop: '2px' }}>{formatTime(lastLockAt)}</div>
        </div>
        <div>
          <div style={{ color: '#64748b', fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>Last Online</div>
          <div style={{ color: '#e2e8f0', fontWeight: 500, marginTop: '2px' }}>{presence === 'online' ? 'Now' : formatTime(lastSeenAt)}</div>
        </div>
      </div>

      {/* Status banners */}
      {lockResult?.success && (
        <div style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          background: 'rgba(34, 197, 94, 0.15)',
          border: '1px solid rgba(34, 197, 94, 0.3)',
          color: '#4ade80',
          padding: '10px 14px',
          borderRadius: '10px',
          fontSize: '13px',
          marginBottom: '14px'
        }}>
          <CheckCircle2 size={16} />
          <span>Screen locked ({lockResult.durationMs}ms)</span>
        </div>
      )}

      {unlockResult?.success && (
        <div style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          background: 'rgba(16, 185, 129, 0.15)',
          border: '1px solid rgba(16, 185, 129, 0.3)',
          color: '#34d399',
          padding: '10px 14px',
          borderRadius: '10px',
          fontSize: '13px',
          marginBottom: '14px'
        }}>
          <CheckCircle2 size={16} />
          <span>Screen unlocked ({unlockResult.durationMs}ms)</span>
        </div>
      )}

      {errorMessage && (
        <div style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          background: 'rgba(239, 68, 68, 0.15)',
          border: '1px solid rgba(239, 68, 68, 0.3)',
          color: '#f87171',
          padding: '10px 14px',
          borderRadius: '10px',
          fontSize: '13px',
          marginBottom: '14px'
        }}>
          <AlertCircle size={16} />
          <span>{errorMessage}</span>
        </div>
      )}

      {/* Dual Lock & Unlock Action Buttons */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
        {/* Lock Button */}
        <button
          onClick={handleLock}
          disabled={locking || unlocking || presence === 'offline'}
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: '8px',
            padding: '14px 12px',
            borderRadius: '14px',
            fontSize: '15px',
            fontWeight: 600,
            color: '#ffffff',
            border: 'none',
            cursor: locking || unlocking || presence === 'offline' ? 'not-allowed' : 'pointer',
            background: presence === 'offline'
              ? 'rgba(71, 85, 105, 0.4)'
              : 'linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%)',
            boxShadow: presence === 'offline'
              ? 'none'
              : '0 4px 16px -2px rgba(99, 102, 241, 0.45)',
            opacity: locking ? 0.75 : presence === 'offline' ? 0.5 : 1,
            transition: 'all 0.15s ease'
          }}
        >
          {locking ? (
            <>
              <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
              <span>Locking...</span>
            </>
          ) : (
            <>
              <Lock size={18} />
              <span>Lock Mac</span>
            </>
          )}
        </button>

        {/* Unlock Button */}
        <button
          onClick={handleUnlockClick}
          disabled={locking || unlocking || presence === 'offline'}
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: '8px',
            padding: '14px 12px',
            borderRadius: '14px',
            fontSize: '15px',
            fontWeight: 600,
            color: '#ffffff',
            border: 'none',
            cursor: locking || unlocking || presence === 'offline' ? 'not-allowed' : 'pointer',
            background: presence === 'offline'
              ? 'rgba(71, 85, 105, 0.4)'
              : 'linear-gradient(135deg, #059669 0%, #0d9488 100%)',
            boxShadow: presence === 'offline'
              ? 'none'
              : '0 4px 16px -2px rgba(16, 185, 129, 0.4)',
            opacity: unlocking ? 0.75 : presence === 'offline' ? 0.5 : 1,
            transition: 'all 0.15s ease'
          }}
        >
          {unlocking ? (
            <>
              <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
              <span>Unlocking...</span>
            </>
          ) : (
            <>
              <Unlock size={18} />
              <span>Unlock Mac</span>
            </>
          )}
        </button>
      </div>

      {/* Password Configuration Modal */}
      {showPasswordModal && (
        <div style={{
          position: 'fixed',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          background: 'rgba(0, 0, 0, 0.75)',
          backdropFilter: 'blur(6px)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 100,
          padding: '20px'
        }}>
          <div style={{
            background: '#1e293b',
            borderRadius: '20px',
            border: '1px solid rgba(255, 255, 255, 0.12)',
            width: '100%',
            maxWidth: '380px',
            padding: '24px',
            boxShadow: '0 20px 40px rgba(0, 0, 0, 0.6)'
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' }}>
              <div style={{
                width: '36px',
                height: '36px',
                borderRadius: '10px',
                background: 'rgba(16, 185, 129, 0.15)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                color: '#34d399'
              }}>
                <KeyRound size={20} />
              </div>
              <div style={{ fontSize: '18px', fontWeight: 600, color: '#f8fafc' }}>
                Unlock {mac.name || 'Mac'}
              </div>
            </div>

            <p style={{ fontSize: '13px', color: '#94a3b8', margin: '0 0 16px 0', lineHeight: 1.5 }}>
              Enter your Mac login password. It is encrypted end-to-end to wake and unlock your screen.
            </p>

            <form onSubmit={handleModalSubmit}>
              <div style={{ marginBottom: '14px' }}>
                <input
                  type="password"
                  placeholder="Mac login password"
                  value={passwordInput}
                  onChange={(e) => setPasswordInput(e.target.value)}
                  autoFocus
                  required
                  style={{
                    width: '100%',
                    padding: '12px 14px',
                    borderRadius: '10px',
                    border: '1px solid rgba(255, 255, 255, 0.15)',
                    background: 'rgba(0, 0, 0, 0.3)',
                    color: '#ffffff',
                    fontSize: '15px',
                    boxSizing: 'border-box',
                    outline: 'none'
                  }}
                />
              </div>

              <label style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                fontSize: '13px',
                color: '#cbd5e1',
                marginBottom: '20px',
                cursor: 'pointer'
              }}>
                <input
                  type="checkbox"
                  checked={rememberPassword}
                  onChange={(e) => setRememberPassword(e.target.checked)}
                  style={{ width: '16px', height: '16px', accentColor: '#10b981' }}
                />
                Remember password on this phone
              </label>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
                <button
                  type="button"
                  onClick={() => setShowPasswordModal(false)}
                  style={{
                    padding: '12px',
                    borderRadius: '10px',
                    border: '1px solid rgba(255, 255, 255, 0.12)',
                    background: 'transparent',
                    color: '#94a3b8',
                    fontSize: '14px',
                    fontWeight: 500,
                    cursor: 'pointer'
                  }}
                >
                  Cancel
                </button>

                <button
                  type="submit"
                  disabled={!passwordInput || unlocking}
                  style={{
                    padding: '12px',
                    borderRadius: '10px',
                    border: 'none',
                    background: 'linear-gradient(135deg, #059669 0%, #0d9488 100%)',
                    color: '#ffffff',
                    fontSize: '14px',
                    fontWeight: 600,
                    cursor: !passwordInput || unlocking ? 'not-allowed' : 'pointer',
                    opacity: !passwordInput || unlocking ? 0.6 : 1,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    gap: '6px'
                  }}
                >
                  {unlocking ? <Loader2 size={16} style={{ animation: 'spin 1s linear infinite' }} /> : <Unlock size={16} />}
                  <span>Unlock</span>
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      <style>{`
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
};
