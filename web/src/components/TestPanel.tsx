import React, { useEffect, useRef, useState } from 'react';
import { AlertCircle, CheckCircle2, FlaskConical, Loader2, Lock, ShieldCheck, X } from 'lucide-react';

/**
 * Hackathon test panel.
 *
 * A small "Test" control in the bottom-left corner opens a password prompt. The relay
 * verifies the password (it lives in relay/server.js, never in this bundle). "Lock All"
 * then asks the relay to send a relay-only `test.lock` frame to every authenticated Mac,
 * so judges can lock demo Macs without pairing a phone.
 */

function wsToHttp(base: string): string {
  return base
    .replace(/^wss:\/\//i, 'https://')
    .replace(/^ws:\/\//i, 'http://')
    .replace(/\/+$/, '');
}

/**
 * The relay serving this page. Using the page origin (rather than the phone's stored pairing
 * relay) keeps the panel pointed at the relay it was actually loaded from, even after a
 * trycloudflare tunnel restart changes the URL.
 */
function getRelayHttpBase(): string {
  if (window.location.port === '5173') {
    const protocol = window.location.protocol === 'https:' ? 'https:' : 'http:';
    return `${protocol}//${window.location.hostname}:8799`;
  }
  return window.location.origin;
}

function hostLabel(base: string): string {
  return base.replace(/^https?:\/\//, '');
}

/**
 * The relay serving this page plus the central fleet relay advertised by /health.
 *
 * Macs register with the fleet relay in addition to their primary relay, so a panel served
 * from a local/tunnel relay can still count and lock Macs that are attached elsewhere.
 */
async function discoverFleetBase(primaryBase: string): Promise<string | null> {
  try {
    const override = localStorage.getItem('distee_fleet_relay_url');
    if (override) {
      const base = wsToHttp(override);
      return base.toLowerCase() === primaryBase.toLowerCase() ? null : base;
    }
  } catch {}

  try {
    const res = await fetch(`${primaryBase}/health`, { cache: 'no-store' });
    if (res.ok) {
      const data = (await res.json()) as { fleet?: unknown };
      if (typeof data.fleet === 'string' && data.fleet) {
        const base = wsToHttp(data.fleet);
        if (base.toLowerCase() !== primaryBase.toLowerCase()) return base;
      }
    }
  } catch {}
  return null;
}

interface TestDeviceResult {
  id: string;
  status: string;
  mechanism?: string;
  durationMs?: number | null;
}

interface TestResponse {
  status?: string;
  message?: string;
  sent?: number;
  locked?: number;
  failed?: number;
  online?: number;
  devices?: { id: string; epoch?: number }[];
  results?: TestDeviceResult[];
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

const metaRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: '8px',
  flexWrap: 'wrap',
  padding: '8px 10px',
  marginBottom: '14px',
  borderRadius: '10px',
  background: 'rgba(255, 255, 255, 0.04)',
  border: '1px solid rgba(255, 255, 255, 0.07)',
  fontSize: '11px',
  color: '#94a3b8',
};

const resultsStyle: React.CSSProperties = {
  marginBottom: '14px',
  borderRadius: '10px',
  border: '1px solid rgba(255, 255, 255, 0.08)',
  overflow: 'hidden',
  fontSize: '11px',
};

const resultRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: '8px',
  padding: '7px 10px',
  background: 'rgba(0, 0, 0, 0.22)',
  borderBottom: '1px solid rgba(255, 255, 255, 0.05)',
};

function isLockedStatus(status: string): boolean {
  return status === 'LOCKED' || status === 'ALREADY_LOCKED';
}

async function postTest(
  base: string,
  path: string,
  password: string
): Promise<{ ok: boolean; httpStatus: number; data: TestResponse; staleRelay: boolean }> {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  const contentType = res.headers.get('content-type') || '';
  // An old relay falls through to the SPA for unknown routes and answers 200 text/html.
  if (!contentType.includes('application/json')) {
    return { ok: false, httpStatus: res.status, data: {}, staleRelay: true };
  }
  const data = (await res.json().catch(() => ({}))) as TestResponse;
  return { ok: res.ok, httpStatus: res.status, data, staleRelay: false };
}

export const TestPanel: React.FC = () => {
  const [stage, setStage] = useState<Stage>('closed');
  const [password, setPassword] = useState('');
  const [checking, setChecking] = useState(false);
  const [locking, setLocking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [primaryBase] = useState(getRelayHttpBase);
  const [fleetBase, setFleetBase] = useState<string | null>(null);
  const [online, setOnline] = useState<number | null>(null);
  const [results, setResults] = useState<TestDeviceResult[] | null>(null);
  // Invalidates in-flight requests when the panel is closed or reopened, so a late response
  // cannot reopen the panel or overwrite a newer attempt.
  const requestIdRef = useRef(0);

  const relayBase = fleetBase ?? primaryBase;
  const relayBases = fleetBase ? [fleetBase, primaryBase] : [primaryBase];

  // Ask the serving relay where the fleet relay lives. The fleet connection is what lets
  // this panel see Macs that registered against a different primary relay.
  useEffect(() => {
    let cancelled = false;
    void discoverFleetBase(primaryBase).then((base) => {
      if (!cancelled) setFleetBase(base);
    });
    return () => {
      cancelled = true;
    };
  }, [primaryBase]);

  const close = () => {
    requestIdRef.current += 1;
    setStage('closed');
    setPassword('');
    setChecking(false);
    setLocking(false);
    setError(null);
    setResult(null);
    setOnline(null);
    setResults(null);
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
    setOnline(null);
    setResults(null);
  };

  // While the panel is open, keep showing how many Macs are attached to the relays the
  // panel can reach (fleet + local), deduplicated by device id. A zero count is the
  // quickest way to spot the panel/agent mismatch.
  useEffect(() => {
    if (stage !== 'panel') return;
    let cancelled = false;

    const refreshStatus = async () => {
      const seen = new Set<string>();
      let reachable = false;
      for (const base of relayBases) {
        try {
          const { ok, data } = await postTest(base, '/api/test/status', password);
          if (ok && data.status === 'ok') {
            reachable = true;
            for (const device of data.devices ?? []) seen.add(device.id);
          }
        } catch {
          // Polling is best-effort; the lock button still works.
        }
      }
      if (!cancelled && reachable) setOnline(seen.size);
    };

    void refreshStatus();
    const interval = setInterval(refreshStatus, 5000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
    // relayBases is derived from fleetBase/primaryBase below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stage, password, primaryBase, fleetBase]);

  const handleAuth = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!password || checking) return;

    const requestId = ++requestIdRef.current;
    setChecking(true);
    setError(null);

    let authed = false;
    let sawStale = false;
    let lastStatus = 0;
    let lastMessage: string | undefined;
    let reachedAny = false;

    for (const base of [primaryBase, ...(fleetBase ? [fleetBase] : [])]) {
      try {
        const { ok, httpStatus, data, staleRelay } = await postTest(base, '/api/test/auth', password);
        if (staleRelay) {
          sawStale = true;
          continue;
        }
        reachedAny = true;
        if (ok) {
          authed = true;
          break;
        }
        lastStatus = httpStatus;
        lastMessage = data.message;
        if (httpStatus === 401 || httpStatus === 429) break;
      } catch {
        // Try the next relay.
      }
    }

    if (requestId === requestIdRef.current) {
      if (authed) {
        setStage('panel');
      } else if (!reachedAny && sawStale) {
        setError(
          `The relay at ${relayBase} is running an older build without the test panel. Restart it (./start.sh) or redeploy it.`
        );
      } else if (lastStatus === 429) {
        setError('Too many attempts. Wait a minute and try again.');
      } else if (lastStatus === 401) {
        setError(lastMessage || 'Incorrect test password');
      } else if (!reachedAny) {
        setError(`Could not reach the relay at ${relayBase}. Check your connection.`);
      } else {
        setError(lastMessage || 'Could not verify the test password. Try again.');
      }
      setChecking(false);
    }
  };

  const handleLockAll = async () => {
    if (locking) return;

    const requestId = ++requestIdRef.current;
    setLocking(true);
    setError(null);
    setResult(null);
    setResults(null);

    // Ask every reachable relay (fleet first, then the one serving this page) so Macs on
    // different primary relays are all locked. Results are merged per device id.
    const merged = new Map<string, TestDeviceResult>();
    let anyOk = false;
    let reachedAny = false;
    let sawUnauthorized = false;
    let sawRateLimited = false;
    let legacySent = 0;
    let lastMessage: string | undefined;

    try {
      await Promise.all(
        relayBases.map(async (base) => {
          try {
            const { ok, httpStatus, data, staleRelay } = await postTest(
              base,
              '/api/test/lock-all',
              password
            );
            if (staleRelay) return;
            reachedAny = true;
            if (ok && data.status === 'ok') {
              anyOk = true;
              if (Array.isArray(data.results)) {
                for (const device of data.results) {
                  const existing = merged.get(device.id);
                  if (
                    !existing ||
                    (!isLockedStatus(existing.status) && isLockedStatus(device.status))
                  ) {
                    merged.set(device.id, device);
                  }
                }
              } else if (typeof data.sent === 'number') {
                legacySent = Math.max(legacySent, data.sent);
              }
            } else if (httpStatus === 401) {
              sawUnauthorized = true;
            } else if (httpStatus === 429) {
              sawRateLimited = true;
            } else {
              lastMessage = data.message;
            }
          } catch {
            // The other relay may still be reachable.
          }
        })
      );

      if (requestId !== requestIdRef.current) return;

      if (!reachedAny) {
        setError(
          `The relay at ${relayBase} is running an older build without the test panel. Restart it (./start.sh) or redeploy it.`
        );
      } else if (anyOk) {
        const unique = Array.from(merged.values());
        const sent = unique.length + (unique.length > 0 ? legacySent : 0);
        const locked = unique.filter((device) => isLockedStatus(device.status)).length;
        setResults(unique.length > 0 ? unique : null);
        setOnline(sent);
        if (sent === 0) {
          setResult(
            `No Macs are connected to the reachable relays (${relayBase}). Start Distee against the same relay and try again.`
          );
        } else if (unique.length === 0) {
          setResult(`Lock signal sent to ${sent} Mac${sent === 1 ? '' : 's'}.`);
        } else if (locked === sent) {
          setResult(`Locked ${locked} of ${sent} Mac${sent === 1 ? '' : 's'}.`);
        } else {
          setResult(
            `Lock signal sent to ${sent} Mac${sent === 1 ? '' : 's'}; ${locked} confirmed locked. ` +
              'Check that Distee has Accessibility permission (or "require password immediately" for display sleep).'
          );
        }
      } else if (sawUnauthorized) {
        setStage('password');
        setError('Session rejected. Enter the test password again.');
      } else if (sawRateLimited) {
        setError('Too many attempts. Wait a minute and try again.');
      } else {
        setError(lastMessage || 'Could not lock the Macs. Try again.');
      }
    } catch {
      if (requestId === requestIdRef.current) {
        setError(`Could not reach the relay at ${relayBase}. Check your connection.`);
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

                <p style={{ margin: '0 0 14px', fontSize: '13px', lineHeight: 1.5, color: '#94a3b8' }}>
                  Locks every Mac registered with the fleet relay, plus any Mac connected
                  directly to this relay. No pairing is required.
                </p>

                <div style={metaRowStyle}>
                  <span style={{ wordBreak: 'break-all' }}>
                    {fleetBase ? `Fleet: ${hostLabel(fleetBase)}` : hostLabel(primaryBase)}
                  </span>
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: '5px', whiteSpace: 'nowrap' }}>
                    <span
                      style={{
                        width: '7px',
                        height: '7px',
                        borderRadius: '50%',
                        background: online === null ? '#94a3b8' : online > 0 ? '#4ade80' : '#f87171',
                      }}
                    />
                    {online === null ? 'Checking…' : `${online} Mac${online === 1 ? '' : 's'} online`}
                  </span>
                </div>

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

                {results && results.length > 0 && (
                  <div style={resultsStyle}>
                    {results.map((device, index) => (
                      <div
                        key={device.id}
                        style={{
                          ...resultRowStyle,
                          borderBottom:
                            index === results.length - 1 ? 'none' : '1px solid rgba(255, 255, 255, 0.05)',
                        }}
                      >
                        <span style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' }}>
                          {device.id}
                        </span>
                        <span style={{ color: isLockedStatus(device.status) ? '#86efac' : '#fca5a5' }}>
                          {device.status}
                          {device.mechanism && device.mechanism !== 'none' ? ` · ${device.mechanism}` : ''}
                        </span>
                      </div>
                    ))}
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
