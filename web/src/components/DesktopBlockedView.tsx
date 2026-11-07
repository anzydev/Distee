import React from 'react';
import { Smartphone } from 'lucide-react';

export const DesktopBlockedView: React.FC = () => {
  const currentUrl = typeof window !== 'undefined' ? window.location.origin : 'https://distee.onrender.com';

  return (
    <div style={{
      backgroundColor: 'var(--dp-color-ground)',
      color: 'var(--dp-color-ink)',
      fontFamily: 'var(--dp-typography-reading)',
      minHeight: '100vh',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '24px',
      boxSizing: 'border-box',
      textAlign: 'center'
    }}>
      {/* Header Badge */}
      <div style={{
        display: 'flex',
        alignItems: 'baseline',
        gap: '12px',
        marginBottom: '48px'
      }}>
        <span style={{
          fontFamily: 'var(--dp-typography-display)',
          fontSize: '28px',
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

      {/* Main Card */}
      <div style={{
        maxWidth: '460px',
        width: '100%',
        backgroundColor: 'var(--dp-color-surface)',
        border: 'var(--dp-border-hairline) solid var(--dp-color-line)',
        borderRadius: 'var(--dp-radius-corner)',
        padding: '44px 32px',
        boxShadow: '0 8px 30px rgba(0, 0, 0, 0.03)',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center'
      }}>
        <div style={{
          width: '64px',
          height: '64px',
          borderRadius: '16px',
          backgroundColor: 'rgba(139, 113, 58, 0.1)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          marginBottom: '24px',
          color: 'var(--dp-color-accent)'
        }}>
          <Smartphone size={32} strokeWidth={1.8} />
        </div>

        <h1 style={{
          fontFamily: 'var(--dp-typography-display)',
          fontSize: '32px',
          fontWeight: 400,
          lineHeight: 1.15,
          margin: '0 0 12px 0',
          color: 'var(--dp-color-ink)'
        }}>
          Mobile & Tablet Devices Only
        </h1>

        <p style={{
          fontSize: '15px',
          lineHeight: 1.6,
          color: 'var(--dp-color-ink-muted)',
          margin: '0 0 28px 0',
          maxWidth: '380px'
        }}>
          Distee is designed to operate exclusively from your phone or tablet. Please open this page on your mobile device to install the app.
        </p>

        <div style={{
          width: '100%',
          padding: '12px 16px',
          backgroundColor: 'var(--dp-color-ground)',
          border: '1px solid var(--dp-color-line)',
          borderRadius: 'var(--dp-radius-corner)',
          fontSize: '14px',
          fontFamily: 'monospace',
          color: 'var(--dp-color-accent-ink)',
          wordBreak: 'break-all',
          userSelect: 'all'
        }}>
          {currentUrl}
        </div>
      </div>
    </div>
  );
};
