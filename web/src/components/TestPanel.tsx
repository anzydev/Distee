import React, { useEffect, useRef, useState } from 'react';
import { AlertCircle, CheckCircle2, FlaskConical, Loader2, Lock, ShieldCheck, X } from 'lucide-react';
import { getRelayUrl } from '../storage/storage';

/**
 * Hackathon test panel.
 *
 * A small "Test" control in the bottom-left corner opens a password prompt. The relay
 * verifies the password (it lives in relay/server.js, never in this bundle). "Lock All"
 * then asks the relay to send a relay-only `test.lock` frame to every authenticated Mac,
 * so judges can lock demo Macs without pairing a phone.
 */

function getRelayHttpBase(): string {
  return getRelayUrl()
    .replace(/^wss:\/\//i, 'https://')
    .replace(/^ws:\/\//i, 'http://')
    .replace(/\/+$/, '');
}

interface TestResponse {
  status?: string;
  message?: string;
  sent?: number;
}

type Stage = 'closed' | 'password' | 'panel';

const fontFamily =
  'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';

const triggerStyle: React.CSSProperties = {
  position: 'fixed',
  left: 'max(14px, env(safe-area-inset-left))',
  bottom: 'max(14px, env(safe-area-inset-bottom))',
  zIndex: 90,
  display: 'inline-flex',
  alignItems: 'center',
  gap: '6px',
  padding: '7px 12px',
  borderRadius: '9999px',
  border: '1px solid rgba(41, 39, 31, 0.18)',
  background: 'rgba(255, 255, 255, 0.78)',
  color: '#514d44',
  fontFamily,
  fontSize: '12px',
  fontWeight: 600,
  letterSpacing: '0.04em',
  cursor: 'pointer',
  backdropFilter: 'blur(6px)',
  WebkitBackdropFilter: 'blur(6px)',
  boxShadow: '0 2px 10px rgba(0, 0, 0, 0.08)',
};

const overlayStyle: React.CSSProperties = {
  position: 'fixed',
  inset: 0,
  zIndex: 200,
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  padding: '16px',
  background: 'rgba(15, 23, 42, 0.72)',
  backdropFilter: 'blur(8px)',
  WebkitBackdropFilter: 'blur(8px)',
};

const cardStyle: React.CSSProperties = {
  position: 'relative',
  width: '100%',
  maxWidth: '380px',
  borderRadius: '20px',
  border: '1px solid rgba(255, 255, 255, 0.1)',
  background: '#0f172a',
  padding: '24px',
  color: '#f8fafc',
  fontFamily,
  boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.7)',
  boxSizing: 'border-box',
};

const closeStyle: React.CSSProperties = {
  position: 'absolute',
  top: '14px',
  right: '14px',
  width: '30px',
  height: '30px',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  borderRadius: '50%',
  border: 'none',
  background: 'rgba(255, 255, 255, 0.06)',
  color: '#94a3b8',
  cursor: 'pointer',
};

const inputStyle: React.CSSProperties = {
  width: '100%',
  boxSizing: 'border-box',
  background: 'rgba(0, 0, 0, 0.3)',
  border: '1px solid rgba(255, 255, 255, 0.12)',
  borderRadius: '12px',
  padding: '12px 14px',
  color: '#ffffff',
  fontSize: '16px',
  marginBottom: '14px',
  outline: 'none',
};

const buttonStyle = (busy: boolean, disabled: boolean): React.CSSProperties => ({
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: '8px',
  width: '100%',
  padding: '14px',
  borderRadius: '14px',
  border: 'none',
  fontSize: '15px',
  fontWeight: 600,
  color: '#ffffff',
  cursor: disabled ? 'not-allowed' : busy ? 'wait' : 'pointer',
  opacity: disabled || busy ? 0.75 : 1,
  background: 'linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%)',
  boxShadow: '0 4px 16px -2px rgba(99, 102, 241, 0.45)',
});

const bannerStyle = (tone: 'error' | 'success'): React.CSSProperties => ({
  display: 'flex',
  alignItems: 'flex-start',
  gap: '8px',
  background: tone === 'error' ? 'rgba(239, 68, 68, 0.14)' : 'rgba(34, 197, 94, 0.14)',
  border: `1px solid ${tone === 'error' ? 'rgba(239, 68, 68, 0.3)' : 'rgba(34, 197, 94, 0.3)'}`,
  color: tone === 'error' ? '#fca5a5' : '#86efac',
  borderRadius: '10px',
  padding: '10px 12px',
  fontSize: '13px',
  lineHeight: 1.4,
  marginBottom: '14px',
});

async function postTest(
  path: string,
  password: string
): Promise<{ ok: boolean; httpStatus: number; data: TestResponse }> {
  const res = await fetch(`${getRelayHttpBase()}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  const data = (await res.json().catch(() => ({}))) as TestResponse;
  return { ok: res.ok, httpStatus: res.status, data };
}

export const TestPanel: React.FC = () => {
  const [stage, setStage] = useState<Stage>('closed');
  const [password, setPassword] = useState('');
  const [checking, setChecking] = useState(false);
  const [locking, setLocking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  // Invalidates in-flight requests when the panel is closed or reopened, so a late response
  // cannot reopen the panel or overwrite a newer attempt.
  const requestIdRef = useRef(0);

  const close = () => {
    requestIdRef.current += 1;
    setStage('closed');
    setPassword('');
    setChecking(false);
    setLocking(false);
    setError(null);
    setResult(null);
  };

  useEffect(() => {
    if (stage === 'closed') return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
    // `close` only calls state setters, so it does not need to be a dependency.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stage]);

  const open = () => {
    requestIdRef.current += 1;
    setStage('password');
    setError(null);
    setResult(null);
  };

  const handleAuth = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!password || checking) return;

    const requestId = ++requestIdRef.current;
    setChecking(true);
    setError(null);
    try {
      const { ok, httpStatus, data } = await postTest('/api/test/auth', password);
      if (requestId !== requestIdRef.current) return;
      if (ok) {
        setStage('panel');
      } else if (httpStatus === 429) {
        setError('Too many attempts. Wait a minute and try again.');
      } else {
        setError(data.message || 'Incorrect test password');
      }
    } catch {
      if (requestId === requestIdRef.current) {
        setError('Could not reach the relay. Check your connection.');
      }
    } finally {
      if (requestId === requestIdRef.current) setChecking(false);
    }
  };

  const handleLockAll = async () => {
    if (locking) return;

    const requestId = ++requestIdRef.current;
    setLocking(true);
    setError(null);
    setResult(null);
    try {
      const { ok, httpStatus, data } = await postTest('/api/test/lock-all', password);
      if (requestId !== requestIdRef.current) return;
      if (ok && data.status === 'ok') {
        const sent = data.sent ?? 0;
        setResult(
          sent > 0
            ? `Lock signal sent to ${sent} Mac${sent === 1 ? '' : 's'}.`
            : 'No Macs are online right now. Make sure Distee is running on the Mac.'
        );
      } else if (httpStatus === 401) {
        setStage('password');
        setError('Session rejected. Enter the test password again.');
      } else if (httpStatus === 429) {
        setError('Too many attempts. Wait a minute and try again.');
      } else {
        setError(data.message || 'Could not lock the Macs. Try again.');
      }
    } catch {
      if (requestId === requestIdRef.current) {
        setError('Could not reach the relay. Check your connection.');
      }
    } finally {
      if (requestId === requestIdRef.current) setLocking(false);
    }
  };

  return (
    <>
      <button type="button" onClick={open} aria-label="Open test panel" style={triggerStyle}>
        <FlaskConical size={13} />
        <span>Test</span>
      </button>

      {stage !== 'closed' && (
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Distee test panel"
          style={overlayStyle}
          onMouseDown={(e) => {
            if (e.target === e.currentTarget && !checking && !locking) close();
          }}
        >
          <div style={cardStyle}>
            <button type="button" onClick={close} aria-label="Close test panel" style={closeStyle}>
              <X size={16} />
            </button>

            {stage === 'password' ? (
              <>
                <div style={{ fontSize: '18px', fontWeight: 600, marginBottom: '6px' }}>
                  Test access
                </div>
                <p style={{ margin: '0 0 16px', fontSize: '13px', lineHeight: 1.5, color: '#94a3b8' }}>
                  Enter the test password to open the demo panel.
                </p>

                <form onSubmit={handleAuth}>
                  <input
                    type="password"
                    value={password}
                    onChange={(e) => {
                      setPassword(e.target.value);
                      setError(null);
                    }}
                    placeholder="Password"
                    autoComplete="off"
                    spellCheck={false}
                    autoFocus
                    style={inputStyle}
                  />

                  {error && (
                    <div style={bannerStyle('error')}>
                      <AlertCircle size={16} style={{ flexShrink: 0, marginTop: '1px' }} />
                      <span>{error}</span>
                    </div>
                  )}

                  <button
                    type="submit"
                    disabled={!password || checking}
                    style={buttonStyle(checking, !password)}
                  >
                    {checking ? (
                      <Loader2 size={16} style={{ animation: 'spin 1s linear infinite' }} />
                    ) : (
                      <Lock size={16} />
                    )}
                    <span>{checking ? 'Checking…' : 'Unlock'}</span>
                  </button>
                </form>
              </>
            ) : (
              <>
                <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '6px' }}>
                  <div
                    style={{
                      width: '34px',
                      height: '34px',
                      borderRadius: '10px',
                      background: 'rgba(99, 102, 241, 0.18)',
                      color: '#a5b4fc',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                    }}
                  >
                    <ShieldCheck size={18} />
                  </div>
                  <div style={{ fontSize: '18px', fontWeight: 600 }}>Test mode</div>
                </div>

                <p style={{ margin: '0 0 18px', fontSize: '13px', lineHeight: 1.5, color: '#94a3b8' }}>
                  Locks every Mac currently connected to the relay. No pairing is required.
                </p>

                {error && (
                  <div style={bannerStyle('error')}>
                    <AlertCircle size={16} style={{ flexShrink: 0, marginTop: '1px' }} />
                    <span>{error}</span>
                  </div>
                )}

                {result && (
                  <div style={bannerStyle('success')}>
                    <CheckCircle2 size={16} style={{ flexShrink: 0, marginTop: '1px' }} />
                    <span>{result}</span>
                  </div>
                )}

                <button
                  type="button"
                  onClick={handleLockAll}
                  disabled={locking}
                  style={buttonStyle(locking, false)}
                >
                  {locking ? (
                    <Loader2 size={18} style={{ animation: 'spin 1s linear infinite' }} />
                  ) : (
                    <Lock size={18} />
                  )}
                  <span>{locking ? 'Locking…' : 'Lock All'}</span>
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
};
