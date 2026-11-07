import React, { useState, useEffect } from 'react';
import { Download, X } from 'lucide-react';

interface WebsiteViewProps {
  onLaunchApp: () => void;
}

export const WebsiteView: React.FC<WebsiteViewProps> = ({ onLaunchApp }) => {
  const [deferredPrompt, setDeferredPrompt] = useState<any>(null);
  const [isInstalled, setIsInstalled] = useState(false);
  const [showIosPrompt, setShowIosPrompt] = useState(false);
  const isIos = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent);

  useEffect(() => {
    const handleBeforeInstall = (e: any) => {
      e.preventDefault();
      setDeferredPrompt(e);
    };
    window.addEventListener('beforeinstallprompt', handleBeforeInstall);

    if (window.matchMedia('(display-mode: standalone)').matches || (window.navigator as any).standalone) {
      setIsInstalled(true);
    }

    return () => window.removeEventListener('beforeinstallprompt', handleBeforeInstall);
  }, []);

  const handleInstallClick = async () => {
    if (deferredPrompt) {
      deferredPrompt.prompt();
      const { outcome } = await deferredPrompt.userChoice;
      if (outcome === 'accepted') {
        setIsInstalled(true);
      }
      setDeferredPrompt(null);
    } else if (isIos) {
      setShowIosPrompt(true);
    } else {
      onLaunchApp();
    }
  };

  return (
    <div style={{
      backgroundColor: 'var(--dp-color-ground)',
      color: 'var(--dp-color-ink)',
      fontFamily: 'var(--dp-typography-reading)',
      minHeight: '100vh',
      display: 'flex',
      flexDirection: 'column',
      lineHeight: 'var(--dp-typography-body-leading)',
    }}>
      {/* Top Header */}
      <header style={{
        maxWidth: '1100px',
        width: '100%',
        margin: '0 auto',
        padding: '36px 28px 24px',
        display: 'flex',
        alignItems: 'baseline',
        justifyContent: 'flex-start',
        borderBottom: 'var(--dp-border-hairline) solid var(--dp-color-line)',
        boxSizing: 'border-box'
      }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: '14px' }}>
          <span style={{
            fontFamily: 'var(--dp-typography-display)',
            fontSize: '26px',
            fontWeight: 500,
            letterSpacing: '0.04em',
            color: 'var(--dp-color-ink)'
          }}>
            DISTEE
          </span>
          <span style={{
            fontSize: 'var(--dp-typography-metadata)',
            textTransform: 'uppercase',
            letterSpacing: '0.12em',
            color: 'var(--dp-color-accent-ink)',
            fontWeight: 600
          }}>
            macOS Remote Lock
          </span>
        </div>
      </header>

      {/* Main Content */}
      <main style={{
        flex: 1,
        maxWidth: '1100px',
        width: '100%',
        margin: '0 auto',
        padding: '0 28px',
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        minHeight: '60vh',
      }}>
        <section style={{ paddingTop: '56px', paddingBottom: '56px' }}>
          <h1 style={{
            fontFamily: 'var(--dp-typography-display)',
            fontSize: 'clamp(42px, 6.5vw, 88px)',
            fontWeight: 400,
            lineHeight: 1.05,
            letterSpacing: '-0.02em',
            margin: '0 0 20px 0',
            color: 'var(--dp-color-ink)'
          }}>
            Lock and unlock your Mac from your phone.
          </h1>

          <p style={{
            fontFamily: 'var(--dp-typography-display)',
            fontStyle: 'italic',
            fontSize: 'clamp(22px, 3.4vw, 44px)',
            fontWeight: 400,
            lineHeight: 1.2,
            color: 'var(--dp-color-accent)',
            margin: '0 0 44px 0',
            paddingLeft: 'clamp(0px, 3vw, 36px)'
          }}>
            — 6-digit code. End-to-end encrypted. Zero accounts.
          </p>

          {/* Action Button: Install Web App ONLY */}
          <div style={{
            display: 'flex',
            flexWrap: 'wrap',
            gap: '16px',
            alignItems: 'center',
            paddingTop: '32px',
            borderTop: 'var(--dp-border-hairline) solid var(--dp-color-line)',
          }}>
            <button
              onClick={handleInstallClick}
              style={{
                backgroundColor: 'var(--dp-color-ink)',
                color: '#ffffff',
                border: 'none',
                borderRadius: 'var(--dp-radius-corner)',
                padding: '16px 36px',
                fontFamily: 'var(--dp-typography-reading)',
                fontSize: '16px',
                fontWeight: 500,
                cursor: 'pointer',
                display: 'inline-flex',
                alignItems: 'center',
                gap: '10px',
                transition: 'background-color var(--dp-motion-interaction)',
              }}
              onMouseEnter={(e) => (e.currentTarget.style.backgroundColor = 'var(--dp-color-action-hover)')}
              onMouseLeave={(e) => (e.currentTarget.style.backgroundColor = 'var(--dp-color-ink)')}
            >
              <Download size={19} />
              <span>{isInstalled ? 'Open Installed App' : 'Install Web App'}</span>
            </button>
          </div>
        </section>
      </main>

      {/* iOS Install Guidance Modal */}
      {showIosPrompt && (
        <div style={{
          position: 'fixed',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          backgroundColor: 'rgba(41, 39, 31, 0.6)',
          backdropFilter: 'blur(4px)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 100,
          padding: '20px'
        }}>
          <div style={{
            backgroundColor: 'var(--dp-color-surface)',
            border: '1px solid var(--dp-color-line)',
            borderRadius: 'var(--dp-radius-corner)',
            maxWidth: '360px',
            width: '100%',
            padding: '24px',
            boxShadow: '0 20px 40px rgba(0,0,0,0.15)'
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '14px' }}>
              <div style={{
                fontFamily: 'var(--dp-typography-display)',
                fontSize: '20px',
                color: 'var(--dp-color-ink)'
              }}>
                Install on iPhone
              </div>
              <button
                onClick={() => setShowIosPrompt(false)}
                style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: 'var(--dp-color-ink-muted)' }}
              >
                <X size={18} />
              </button>
            </div>

            <ol style={{ fontSize: '14px', color: 'var(--dp-color-ink)', paddingLeft: '20px', lineHeight: 1.8, margin: '0 0 20px 0' }}>
              <li>Tap <strong>Share</strong> in Safari (box with up arrow).</li>
              <li>Select <strong>Add to Home Screen</strong>.</li>
              <li>Tap <strong>Add</strong>.</li>
            </ol>

            <button
              onClick={() => {
                setShowIosPrompt(false);
                onLaunchApp();
              }}
              style={{
                width: '100%',
                backgroundColor: 'var(--dp-color-ink)',
                color: '#ffffff',
                border: 'none',
                borderRadius: 'var(--dp-radius-corner)',
                padding: '12px',
                fontSize: '14px',
                fontWeight: 500,
                cursor: 'pointer'
              }}
            >
              Open Web App
            </button>
          </div>
        </div>
      )}
    </div>
  );
};
