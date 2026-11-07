import React, { useState, useEffect, useRef } from 'react';
import {
  Shield,
  Laptop,
  Lock,
  Unlock,
  KeyRound,
  Trash2,
  MoreVertical,
  Camera,
  CheckCircle2,
  AlertCircle,
  Loader2,
  ArrowLeft,
  Smartphone,
  Plus,
  RefreshCw
} from 'lucide-react';
import {
  PairedMac,
  getPairedMacs,
  removePairedMac,
  getMacUnlockPassword,
  setMacUnlockPassword,
  hasMacUnlockPassword
} from '../storage/storage';
import { transports, DevicePresence, LockExecutionResult, UnlockExecutionResult } from '../services/transport';
import { resolvePairingCode, executePairingHandshake, QRPayload } from '../services/pairing';
import { PairingModal } from './PairingModal';

interface MobileAppViewProps {
  onBackToWebsite: () => void;
  initialPairPayload?: string | null;
}

export const MobileAppView: React.FC<MobileAppViewProps> = ({ onBackToWebsite, initialPairPayload }) => {
  const [macs, setMacs] = useState<PairedMac[]>([]);
  const [digits, setDigits] = useState(['', '', '', '', '', '']);
  const [connecting, setConnecting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [confCode, setConfCode] = useState<string | null>(null);
  const [showQRScanner, setShowQRScanner] = useState(false);
  const [selectedMacForPassword, setSelectedMacForPassword] = useState<PairedMac | null>(null);
  const [passwordInput, setPasswordInput] = useState('');
  const [rememberPassword, setRememberPassword] = useState(true);

  // Per-Mac interaction states: deviceId -> { locking, unlocking, lockResult, unlockResult, errorMessage, showMenu }
  const [macStates, setMacStates] = useState<Record<string, {
    locking?: boolean;
    unlocking?: boolean;
    lockResult?: LockExecutionResult | null;
    unlockResult?: UnlockExecutionResult | null;
    error?: string | null;
    menuOpen?: boolean;
    presence?: DevicePresence;
  }>>({});

  const digitInputRefs = useRef<(HTMLInputElement | null)[]>([]);

  useEffect(() => {
    refreshMacs();
    if (initialPairPayload) {
      setShowQRScanner(true);
    }
  }, [initialPairPayload]);

  const refreshMacs = () => {
    const list = getPairedMacs();
    setMacs(list);

    // Initialize presence listeners
    list.forEach((m) => {
      const transport = transports.getOrCreate(m.deviceId);
      updateMacState(m.deviceId, { presence: transport.presence });

      transport.onPresenceChange = (status) => {
        updateMacState(m.deviceId, { presence: status });
      };
      transport.connect();
    });
  };

  const updateMacState = (deviceId: string, update: Partial<typeof macStates[string]>) => {
    setMacStates((prev) => ({
      ...prev,
      [deviceId]: { ...prev[deviceId], ...update },
    }));
  };

  // Handle 6-Digit input typing
  const handleDigitChange = (index: number, val: string) => {
    const char = val.slice(-1).replace(/[^0-9]/g, '');
    const nextDigits = [...digits];
    nextDigits[index] = char;
    setDigits(nextDigits);
    setErrorMessage(null);

    // Auto-advance
    if (char && index < 5) {
      digitInputRefs.current[index + 1]?.focus();
    }

    // If all 6 digits entered, auto-trigger connect
    if (char && index === 5 && nextDigits.every((d) => d !== '')) {
      const code = nextDigits.join('');
      void handleConnectWithCode(code);
    }
  };

  const handleDigitKeyDown = (index: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace' && !digits[index] && index > 0) {
      digitInputRefs.current[index - 1]?.focus();
    }
  };

  const handlePasteCode = (e: React.ClipboardEvent<HTMLInputElement>) => {
    e.preventDefault();
    const pasted = e.clipboardData.getData('text').replace(/[^0-9]/g, '').slice(0, 6);
    if (!pasted) return;

    const nextDigits = ['', '', '', '', '', ''];
    for (let i = 0; i < pasted.length; i++) {
      nextDigits[i] = pasted[i];
    }
    setDigits(nextDigits);

    if (pasted.length === 6) {
      void handleConnectWithCode(pasted);
    } else {
      digitInputRefs.current[pasted.length]?.focus();
    }
  };

  // Connect using 6-Digit Code
  const handleConnectWithCode = async (codeToUse?: string) => {
    const code = codeToUse || digits.join('');
    if (code.length !== 6) {
      setErrorMessage('Please enter all 6 digits from your Mac');
      return;
    }

    setConnecting(true);
    setErrorMessage(null);
    setStatusMessage('Connecting to cloud relay...');
    setConfCode(null);

    try {
      const qrPayload: QRPayload = await resolvePairingCode(code);
      setStatusMessage(`Found ${qrPayload.name}. Establishing encrypted channel...`);

      const result = await executePairingHandshake(
        qrPayload,
        'Mobile Phone',
        (code) => {
          setConfCode(code);
          setStatusMessage('Waiting for approval on your Mac...');
        },
        30000
      );

      setStatusMessage(null);
      setConfCode(null);
      setDigits(['', '', '', '', '', '']);
      refreshMacs();
    } catch (err: any) {
      setErrorMessage(err.message || 'Failed to connect. Make sure the code on your Mac has not expired.');
      setStatusMessage(null);
      setConfCode(null);
    } finally {
      setConnecting(false);
    }
  };

  // Remote Lock Handler
  const handleLock = async (mac: PairedMac) => {
    const currentState = macStates[mac.deviceId];
    if (currentState?.locking || currentState?.presence === 'offline') return;

    updateMacState(mac.deviceId, { locking: true, error: null, lockResult: null, unlockResult: null });

    try {
      const transport = transports.getOrCreate(mac.deviceId);
      const result = await transport.sendLockCommand(12000);
      updateMacState(mac.deviceId, { lockResult: result, locking: false });
    } catch (err: any) {
      updateMacState(mac.deviceId, { error: err.message || 'Lock command failed', locking: false });
    }
  };

  // Remote Unlock Handler
  const handleUnlockClick = (mac: PairedMac) => {
    const saved = getMacUnlockPassword(mac.deviceId);
    if (saved) {
      void executeUnlock(mac, saved);
    } else {
      setPasswordInput('');
      setRememberPassword(true);
      setSelectedMacForPassword(mac);
    }
  };

  const executeUnlock = async (mac: PairedMac, pwd: string) => {
    if (!pwd) return;

    updateMacState(mac.deviceId, { unlocking: true, error: null, lockResult: null, unlockResult: null });

    try {
      const transport = transports.getOrCreate(mac.deviceId);
      const result = await transport.sendUnlockCommand(pwd, 15000);
      updateMacState(mac.deviceId, { unlockResult: result, unlocking: false });
      setSelectedMacForPassword(null);
      setPasswordInput('');
    } catch (err: any) {
      updateMacState(mac.deviceId, { error: err.message || 'Unlock command failed', unlocking: false });
    }
  };

  const handlePasswordModalSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedMacForPassword || !passwordInput) return;

    if (rememberPassword) {
      setMacUnlockPassword(selectedMacForPassword.deviceId, passwordInput);
    }
    void executeUnlock(selectedMacForPassword, passwordInput);
  };

  const handleUnpair = async (mac: PairedMac) => {
    if (!confirm(`Unpair ${mac.name}? You will need to enter a new 6-digit code on the Mac to connect again.`)) return;

    const transport = transports.getOrCreate(mac.deviceId);
    try {
      await transport.sendUnpairCommand();
    } catch {}
    transports.remove(mac.deviceId);
    removePairedMac(mac.deviceId);
    refreshMacs();
  };

  return (
    <div style={{
      backgroundColor: 'var(--sketch-color-ground)',
      color: 'var(--sketch-color-ink)',
      fontFamily: 'var(--sketch-typography-reading-face)',
      fontSize: 'var(--sketch-typography-reading)',
      minHeight: '100vh',
      display: 'flex',
      flexDirection: 'column',
      padding: '16px',
      boxSizing: 'border-box',
      position: 'relative',
    }}>
      {/* Top Working Sheet Navigation Bar */}
      <header style={{
        maxWidth: '540px',
        width: '100%',
        margin: '0 auto 20px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingBottom: '12px',
        borderBottom: 'var(--sketch-border-fine-stroke) dashed var(--sketch-color-line)',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <button
            onClick={onBackToWebsite}
            style={{
              background: 'transparent',
              border: 'none',
              cursor: 'pointer',
              color: 'var(--sketch-color-annotation)',
              fontSize: '17px',
              fontFamily: 'var(--sketch-typography-reading-face)',
              display: 'flex',
              alignItems: 'center',
              gap: '4px',
              padding: '4px 6px',
            }}
          >
            <ArrowLeft size={16} />
            <span>specs</span>
          </button>
          <span style={{ color: 'var(--sketch-color-line)' }}>|</span>
          <span style={{
            fontFamily: 'var(--sketch-typography-display-face)',
            fontSize: '22px',
            fontWeight: 700,
            color: 'var(--sketch-color-ink)'
          }}>
            Distee ✎ working sheet
          </span>
        </div>

        <div style={{
          backgroundColor: 'var(--sketch-color-highlight)',
          border: '1px solid var(--sketch-color-line)',
          borderRadius: '4px',
          padding: '2px 8px',
          fontSize: '15px',
          fontFamily: 'var(--sketch-typography-reading-face)',
          color: 'var(--sketch-color-annotation)',
          transform: 'rotate(-1.5deg)'
        }}>
          ● cloud live
        </div>
      </header>

      {/* Main Working Sheet Container */}
      <main style={{ maxWidth: '540px', width: '100%', margin: '0 auto', flex: 1, display: 'flex', flexDirection: 'column', gap: '20px' }}>
        
        {/* Unpaired State: 6-Digit Code Connection */}
        {macs.length === 0 ? (
          <div style={{
            backgroundColor: 'var(--sketch-color-scrap)',
            border: 'var(--sketch-border-fine-stroke) solid var(--sketch-color-line)',
            borderRadius: 'var(--sketch-radius-control)',
            padding: '28px 22px',
            boxShadow: '2px 4px 0px rgba(56, 53, 47, 0.15)',
            position: 'relative'
          }}>
            {/* Taped strip at top */}
            <div style={{
              position: 'absolute',
              top: '-10px',
              left: '50%',
              transform: 'translateX(-50%)',
              width: '90px',
              height: '20px',
              backgroundColor: 'rgba(240, 223, 160, 0.7)',
              border: '1px dashed rgba(179, 172, 157, 0.5)',
              borderRadius: '2px'
            }} />

            <div style={{
              fontFamily: 'var(--sketch-typography-display-face)',
              fontSize: '28px',
              fontWeight: 700,
              color: 'var(--sketch-color-ink)',
              marginBottom: '6px'
            }}>
              pair your mac
            </div>

            <p style={{
              margin: '0 0 20px 0',
              color: 'var(--sketch-color-annotation)',
              fontSize: '19px',
              lineHeight: 1.3
            }}>
              enter the 6-digit code shown on your Mac's screen:
            </p>

            {/* 6-Digit Input Boxes */}
            <div style={{
              display: 'flex',
              justifyContent: 'center',
              gap: '8px',
              marginBottom: '20px'
            }}>
              {digits.map((digit, index) => (
                <input
                  key={index}
                  ref={(el) => (digitInputRefs.current[index] = el)}
                  type="text"
                  inputMode="numeric"
                  pattern="[0-9]*"
                  maxLength={1}
                  value={digit}
                  onChange={(e) => handleDigitChange(index, e.target.value)}
                  onKeyDown={(e) => handleDigitKeyDown(index, e)}
                  onPaste={handlePasteCode}
                  autoFocus={index === 0}
                  style={{
                    width: '44px',
                    height: '56px',
                    textAlign: 'center',
                    fontFamily: 'var(--sketch-typography-display-face)',
                    fontSize: '30px',
                    fontWeight: 700,
                    color: 'var(--sketch-color-ink)',
                    backgroundColor: '#ffffff',
                    border: '1.5px solid var(--sketch-color-line)',
                    borderRadius: '6px 3px 8px 4px',
                    boxShadow: '1px 2px 0px rgba(56, 53, 47, 0.2)',
                    outline: 'none',
                    transition: 'all var(--sketch-motion-control)'
                  }}
                  onFocus={(e) => (e.target.style.borderColor = 'var(--sketch-color-annotation)')}
                  onBlur={(e) => (e.target.style.borderColor = 'var(--sketch-color-line)')}
                />
              ))}
            </div>

            {/* Status & Confirmation Code Feedback */}
            {confCode && (
              <div style={{
                backgroundColor: 'var(--sketch-color-highlight)',
                border: '1.5px dashed var(--sketch-color-accent)',
                borderRadius: '6px',
                padding: '12px',
                textAlign: 'center',
                marginBottom: '16px'
              }}>
                <div style={{ fontSize: '16px', color: 'var(--sketch-color-accent)', fontWeight: 600 }}>
                  CONFIRMATION CODE MATCH:
                </div>
                <div style={{ fontFamily: 'var(--sketch-typography-display-face)', fontSize: '32px', fontWeight: 700, color: 'var(--sketch-color-ink)' }}>
                  {confCode}
                </div>
                <div style={{ fontSize: '15px', color: 'var(--sketch-color-annotation)' }}>
                  Click "Allow" on your Mac if this matches!
                </div>
              </div>
            )}

            {statusMessage && !confCode && (
              <div style={{
                textAlign: 'center',
                color: 'var(--sketch-color-annotation)',
                fontSize: '18px',
                marginBottom: '14px',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: '8px'
              }}>
                <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
                <span>{statusMessage}</span>
              </div>
            )}

            {errorMessage && (
              <div style={{
                color: 'var(--sketch-color-accent)',
                fontSize: '18px',
                marginBottom: '16px',
                padding: '8px 12px',
                backgroundColor: 'rgba(158, 58, 46, 0.08)',
                border: '1px solid var(--sketch-color-accent)',
                borderRadius: '6px'
              }}>
                {errorMessage}
              </div>
            )}

            {/* Connect Button */}
            <button
              onClick={() => handleConnectWithCode()}
              disabled={connecting || digits.some((d) => d === '')}
              style={{
                width: '100%',
                backgroundColor: 'var(--sketch-color-accent)',
                color: '#ffffff',
                border: '1.5px solid #6b1f15',
                borderRadius: 'var(--sketch-radius-control)',
                boxShadow: '2px 3px 0px #38352f',
                padding: '14px',
                fontSize: '22px',
                fontFamily: 'var(--sketch-typography-display-face)',
                fontWeight: 700,
                cursor: connecting || digits.some((d) => d === '') ? 'not-allowed' : 'pointer',
                opacity: connecting || digits.some((d) => d === '') ? 0.6 : 1,
                marginBottom: '16px',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: '8px',
                transition: 'all var(--sketch-motion-control)'
              }}
            >
              {connecting ? (
                <>
                  <Loader2 size={20} style={{ animation: 'spin 1s linear infinite' }} />
                  <span>Connecting...</span>
                </>
              ) : (
                <span>Connect Mac →</span>
              )}
            </button>

            {/* Optional QR Code Button */}
            <div style={{ textAlign: 'center' }}>
              <button
                onClick={() => setShowQRScanner(true)}
                style={{
                  background: 'transparent',
                  border: 'none',
                  color: 'var(--sketch-color-annotation)',
                  fontFamily: 'var(--sketch-typography-reading-face)',
                  fontSize: '18px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: '6px',
                  textDecoration: 'underline',
                  textUnderlineOffset: '3px'
                }}
              >
                <Camera size={16} />
                <span>or scan QR code with camera (optional)</span>
              </button>
            </div>
          </div>
        ) : (
          /* Paired Macs Working Sheet */
          <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <div style={{
                fontFamily: 'var(--sketch-typography-display-face)',
                fontSize: '24px',
                fontWeight: 700,
                color: 'var(--sketch-color-ink)'
              }}>
                paired macs ({macs.length})
              </div>

              <button
                onClick={() => {
                  setDigits(['', '', '', '', '', '']);
                  setErrorMessage(null);
                  setMacs([]); // Trigger pair entry view
                }}
                style={{
                  background: 'var(--sketch-color-scrap)',
                  border: '1.5px solid var(--sketch-color-line)',
                  borderRadius: 'var(--sketch-radius-control)',
                  boxShadow: '1px 2px 0px var(--sketch-color-ink)',
                  fontFamily: 'var(--sketch-typography-reading-face)',
                  fontSize: '16px',
                  padding: '6px 12px',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '4px'
                }}
              >
                <Plus size={15} />
                <span>+ add another mac</span>
              </button>
            </div>

            {/* List of Paired Mac Cards */}
            {macs.map((mac) => {
              const state = macStates[mac.deviceId] || {};
              const isOnline = state.presence === 'online';

              return (
                <div
                  key={mac.deviceId}
                  style={{
                    backgroundColor: 'var(--sketch-color-scrap)',
                    border: 'var(--sketch-border-fine-stroke) solid var(--sketch-color-line)',
                    borderRadius: 'var(--sketch-radius-control)',
                    padding: '20px',
                    boxShadow: '2px 4px 0px rgba(56, 53, 47, 0.15)',
                    position: 'relative'
                  }}
                >
                  {/* Tape header strip */}
                  <div style={{
                    position: 'absolute',
                    top: '-8px',
                    left: '24px',
                    width: '60px',
                    height: '16px',
                    backgroundColor: 'rgba(240, 223, 160, 0.65)',
                    border: '1px dashed rgba(179, 172, 157, 0.4)',
                    borderRadius: '2px'
                  }} />

                  {/* Header row */}
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '14px' }}>
                    <div>
                      <div style={{
                        fontFamily: 'var(--sketch-typography-display-face)',
                        fontSize: '22px',
                        fontWeight: 700,
                        color: 'var(--sketch-color-ink)'
                      }}>
                        {mac.name || 'Mac'}
                      </div>
                      <div style={{ fontSize: '15px', color: 'var(--sketch-color-ink-muted)', fontFamily: 'monospace' }}>
                        id: {mac.deviceId}
                      </div>
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                      <span style={{
                        backgroundColor: isOnline ? 'var(--sketch-color-highlight)' : '#e5e0d3',
                        border: '1px solid var(--sketch-color-line)',
                        borderRadius: '4px',
                        padding: '2px 8px',
                        fontSize: '14px',
                        color: isOnline ? '#2b5329' : 'var(--sketch-color-ink-muted)',
                        fontWeight: 600
                      }}>
                        {isOnline ? '✓ online' : '○ offline'}
                      </span>

                      <button
                        onClick={() => updateMacState(mac.deviceId, { menuOpen: !state.menuOpen })}
                        style={{
                          background: 'transparent',
                          border: 'none',
                          cursor: 'pointer',
                          color: 'var(--sketch-color-ink-muted)',
                          padding: '4px'
                        }}
                      >
                        <MoreVertical size={18} />
                      </button>
                    </div>
                  </div>

                  {/* Dropdown Menu */}
                  {state.menuOpen && (
                    <div style={{
                      backgroundColor: '#ffffff',
                      border: '1.5px solid var(--sketch-color-line)',
                      borderRadius: '6px',
                      boxShadow: '2px 3px 0px rgba(0,0,0,0.1)',
                      padding: '6px',
                      marginBottom: '14px'
                    }}>
                      <button
                        onClick={() => {
                          setMacUnlockPassword(mac.deviceId, null);
                          updateMacState(mac.deviceId, { menuOpen: false });
                          alert('Saved unlock password cleared for this Mac');
                        }}
                        style={{
                          width: '100%',
                          textAlign: 'left',
                          background: 'transparent',
                          border: 'none',
                          padding: '6px 10px',
                          fontSize: '16px',
                          cursor: 'pointer',
                          display: 'flex',
                          alignItems: 'center',
                          gap: '6px',
                          color: 'var(--sketch-color-ink)'
                        }}
                      >
                        <KeyRound size={15} />
                        <span>Clear Saved Unlock Password</span>
                      </button>

                      <button
                        onClick={() => {
                          updateMacState(mac.deviceId, { menuOpen: false });
                          handleUnpair(mac);
                        }}
                        style={{
                          width: '100%',
                          textAlign: 'left',
                          background: 'transparent',
                          border: 'none',
                          padding: '6px 10px',
                          fontSize: '16px',
                          cursor: 'pointer',
                          display: 'flex',
                          alignItems: 'center',
                          gap: '6px',
                          color: 'var(--sketch-color-accent)'
                        }}
                      >
                        <Trash2 size={15} />
                        <span>Unpair Mac</span>
                      </button>
                    </div>
                  )}

                  {/* Feedback Banners */}
                  {state.lockResult?.success && (
                    <div style={{
                      backgroundColor: 'var(--sketch-color-highlight)',
                      border: '1px solid var(--sketch-color-line)',
                      borderRadius: '6px',
                      padding: '8px 12px',
                      fontSize: '16px',
                      color: '#2b5329',
                      marginBottom: '14px',
                      display: 'flex',
                      alignItems: 'center',
                      gap: '6px'
                    }}>
                      <CheckCircle2 size={16} />
                      <span>Screen locked! ({state.lockResult.durationMs}ms)</span>
                    </div>
                  )}

                  {state.unlockResult?.success && (
                    <div style={{
                      backgroundColor: 'rgba(52, 76, 105, 0.1)',
                      border: '1px solid var(--sketch-color-annotation)',
                      borderRadius: '6px',
                      padding: '8px 12px',
                      fontSize: '16px',
                      color: 'var(--sketch-color-annotation)',
                      marginBottom: '14px',
                      display: 'flex',
                      alignItems: 'center',
                      gap: '6px'
                    }}>
                      <CheckCircle2 size={16} />
                      <span>Screen unlocked! ({state.unlockResult.durationMs}ms)</span>
                    </div>
                  )}

                  {state.error && (
                    <div style={{
                      backgroundColor: 'rgba(158, 58, 46, 0.08)',
                      border: '1px solid var(--sketch-color-accent)',
                      borderRadius: '6px',
                      padding: '8px 12px',
                      fontSize: '16px',
                      color: 'var(--sketch-color-accent)',
                      marginBottom: '14px'
                    }}>
                      {state.error}
                    </div>
                  )}

                  {/* Dual Action Buttons: Lock & Unlock */}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
                    {/* Lock Mac Button */}
                    <button
                      onClick={() => handleLock(mac)}
                      disabled={state.locking || state.unlocking || !isOnline}
                      style={{
                        backgroundColor: isOnline ? 'var(--sketch-color-accent)' : '#d5cfc4',
                        color: isOnline ? '#ffffff' : '#6b665c',
                        border: '1.5px solid #38352f',
                        borderRadius: 'var(--sketch-radius-control)',
                        boxShadow: isOnline ? '2px 3px 0px #38352f' : 'none',
                        padding: '12px 14px',
                        fontSize: '20px',
                        fontFamily: 'var(--sketch-typography-display-face)',
                        fontWeight: 700,
                        cursor: state.locking || !isOnline ? 'not-allowed' : 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        gap: '6px',
                        transition: 'all var(--sketch-motion-control)'
                      }}
                    >
                      {state.locking ? (
                        <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
                      ) : (
                        <Lock size={18} />
                      )}
                      <span>Lock Mac</span>
                    </button>

                    {/* Unlock Mac Button */}
                    <button
                      onClick={() => handleUnlockClick(mac)}
                      disabled={state.locking || state.unlocking || !isOnline}
                      style={{
                        backgroundColor: isOnline ? 'var(--sketch-color-scrap)' : '#d5cfc4',
                        color: isOnline ? 'var(--sketch-color-ink)' : '#6b665c',
                        border: '1.5px solid #38352f',
                        borderRadius: 'var(--sketch-radius-control)',
                        boxShadow: isOnline ? '2px 3px 0px #38352f' : 'none',
                        padding: '12px 14px',
                        fontSize: '20px',
                        fontFamily: 'var(--sketch-typography-display-face)',
                        fontWeight: 700,
                        cursor: state.unlocking || !isOnline ? 'not-allowed' : 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        gap: '6px',
                        transition: 'all var(--sketch-motion-control)'
                      }}
                    >
                      {state.unlocking ? (
                        <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
                      ) : (
                        <Unlock size={18} />
                      )}
                      <span>Unlock Mac</span>
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* Hand-drawn Note footer */}
        <div style={{
          backgroundColor: 'rgba(240, 223, 160, 0.45)',
          border: '1px dashed var(--sketch-color-line)',
          borderRadius: '6px',
          padding: '12px 14px',
          fontSize: '16px',
          color: 'var(--sketch-color-annotation)',
          lineHeight: 1.4
        }}>
          💡 <strong>Tip for Phones:</strong> Tap Share in Safari or Chrome Menu and select <strong>"Add to Home Screen"</strong> to use Distee as a full-screen app!
        </div>
      </main>

      {/* Password Prompt Modal (Paper Scrap Style) */}
      {selectedMacForPassword && (
        <div style={{
          position: 'fixed',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          backgroundColor: 'rgba(56, 53, 47, 0.65)',
          backdropFilter: 'blur(3px)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 100,
          padding: '16px'
        }}>
          <div style={{
            backgroundColor: 'var(--sketch-color-scrap)',
            border: '2px solid var(--sketch-color-ink)',
            borderRadius: 'var(--sketch-radius-control)',
            boxShadow: '3px 5px 0px var(--sketch-color-ink)',
            maxWidth: '360px',
            width: '100%',
            padding: '24px',
            position: 'relative'
          }}>
            <div style={{
              fontFamily: 'var(--sketch-typography-display-face)',
              fontSize: '24px',
              fontWeight: 700,
              color: 'var(--sketch-color-ink)',
              marginBottom: '6px'
            }}>
              unlock {selectedMacForPassword.name}
            </div>

            <p style={{
              fontSize: '17px',
              color: 'var(--sketch-color-annotation)',
              margin: '0 0 16px 0',
              lineHeight: 1.3
            }}>
              enter your Mac login password. It is encrypted end-to-end to wake and unlock your screen:
            </p>

            <form onSubmit={handlePasswordModalSubmit}>
              <input
                type="password"
                placeholder="Mac password"
                value={passwordInput}
                onChange={(e) => setPasswordInput(e.target.value)}
                autoFocus
                required
                style={{
                  width: '100%',
                  padding: '12px',
                  fontFamily: 'var(--sketch-typography-reading-face)',
                  fontSize: '20px',
                  backgroundColor: '#ffffff',
                  border: '1.5px solid var(--sketch-color-ink)',
                  borderRadius: '6px',
                  boxShadow: '1px 2px 0px rgba(0,0,0,0.1)',
                  outline: 'none',
                  marginBottom: '14px',
                  boxSizing: 'border-box'
                }}
              />

              <label style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                fontSize: '17px',
                color: 'var(--sketch-color-ink)',
                marginBottom: '20px',
                cursor: 'pointer'
              }}>
                <input
                  type="checkbox"
                  checked={rememberPassword}
                  onChange={(e) => setRememberPassword(e.target.checked)}
                  style={{ width: '18px', height: '18px', accentColor: 'var(--sketch-color-accent)' }}
                />
                remember on this phone
              </label>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
                <button
                  type="button"
                  onClick={() => setSelectedMacForPassword(null)}
                  style={{
                    backgroundColor: 'transparent',
                    border: '1.5px solid var(--sketch-color-ink)',
                    borderRadius: '6px',
                    padding: '10px',
                    fontFamily: 'var(--sketch-typography-display-face)',
                    fontSize: '18px',
                    cursor: 'pointer'
                  }}
                >
                  Cancel
                </button>

                <button
                  type="submit"
                  disabled={!passwordInput}
                  style={{
                    backgroundColor: 'var(--sketch-color-accent)',
                    color: '#ffffff',
                    border: '1.5px solid #38352f',
                    borderRadius: '6px',
                    boxShadow: '2px 2px 0px #38352f',
                    padding: '10px',
                    fontFamily: 'var(--sketch-typography-display-face)',
                    fontSize: '18px',
                    fontWeight: 700,
                    cursor: !passwordInput ? 'not-allowed' : 'pointer',
                    opacity: !passwordInput ? 0.6 : 1
                  }}
                >
                  Unlock →
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Optional Camera QR Scanner Modal */}
      {showQRScanner && (
        <PairingModal
          initialPayload={initialPairPayload}
          onClose={() => setShowQRScanner(false)}
          onSuccess={() => {
            setShowQRScanner(false);
            refreshMacs();
          }}
        />
      )}
    </div>
  );
};

