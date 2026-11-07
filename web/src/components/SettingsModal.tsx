import React, { useState } from 'react';
import { X, Server, Shield, Check } from 'lucide-react';
import { getRelayUrl, setRelayUrl } from '../storage/storage';

interface SettingsModalProps {
  onClose: () => void;
}

export const SettingsModal: React.FC<SettingsModalProps> = ({ onClose }) => {
  const [relayUrl, setRelayUrlInput] = useState(getRelayUrl());
  const [saved, setSaved] = useState(false);

  const handleSave = (e: React.FormEvent) => {
    e.preventDefault();
    setRelayUrl(relayUrl.trim());
    setSaved(true);
    setTimeout(() => {
      setSaved(false);
      onClose();
      window.location.reload();
    }, 800);
  };

  return (
    <div style={{
      position: 'fixed',
      top: 0,
      left: 0,
      right: 0,
      bottom: 0,
      background: 'rgba(0, 0, 0, 0.85)',
      backdropFilter: 'blur(8px)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '16px',
      zIndex: 50
    }}>
      <div style={{
        background: '#0f172a',
        borderRadius: '24px',
        border: '1px solid rgba(255, 255, 255, 0.1)',
        width: '100%',
        maxWidth: '440px',
        padding: '24px',
        position: 'relative',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.7)'
      }}>
        <button
          onClick={onClose}
          style={{
            position: 'absolute',
            top: '18px',
            right: '18px',
            background: 'rgba(255,255,255,0.06)',
            border: 'none',
            color: '#94a3b8',
            width: '32px',
            height: '32px',
            borderRadius: '50%',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center'
          }}
        >
          <X size={18} />
        </button>

        <div style={{ fontSize: '20px', fontWeight: 600, color: '#f8fafc', marginBottom: '6px' }}>
          Settings
        </div>
        <div style={{ fontSize: '13px', color: '#94a3b8', marginBottom: '20px' }}>
          Configure connection and relay parameters
        </div>

        <form onSubmit={handleSave}>
          <div style={{ marginBottom: '18px' }}>
            <label style={{ display: 'block', fontSize: '13px', fontWeight: 500, color: '#e2e8f0', marginBottom: '6px' }}>
              Relay WebSocket URL
            </label>
            <div style={{ position: 'relative' }}>
              <input
                type="text"
                value={relayUrl}
                onChange={(e) => setRelayUrlInput(e.target.value)}
                placeholder="ws://localhost:8799"
                style={{
                  width: '100%',
                  boxSizing: 'border-box',
                  background: 'rgba(0,0,0,0.3)',
                  border: '1px solid rgba(255,255,255,0.1)',
                  borderRadius: '12px',
                  padding: '12px 14px',
                  color: '#fff',
                  fontSize: '16px', // >=16px stops iOS Safari zooming the page on focus
                  fontFamily: 'monospace'
                }}
              />
            </div>
            <div style={{ fontSize: '12px', color: '#64748b', marginTop: '6px' }}>
              Default: ws://localhost:8799 or your deployed Cloudflare Worker relay.
            </div>
          </div>

          <div style={{
            background: 'rgba(99, 102, 241, 0.08)',
            border: '1px solid rgba(99, 102, 241, 0.18)',
            borderRadius: '12px',
            padding: '12px',
            marginBottom: '20px',
            fontSize: '12px',
            color: '#c7d2fe',
            display: 'flex',
            gap: '10px'
          }}>
            <Shield size={20} style={{ flexShrink: 0, marginTop: '2px' }} />
            <div>
              Distee uses zero-knowledge relays. The relay forwards encrypted frames without having access to private keys or plaintext data.
            </div>
          </div>

          <button
            type="submit"
            style={{
              width: '100%',
              background: saved ? '#22c55e' : '#4f46e5',
              border: 'none',
              borderRadius: '12px',
              padding: '14px',
              color: '#fff',
              fontSize: '15px',
              fontWeight: 600,
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              gap: '8px',
              transition: 'all 0.2s ease'
            }}
          >
            {saved ? (
              <>
                <Check size={18} />
                <span>Saved & Reloading...</span>
              </>
            ) : (
              <span>Save Settings</span>
            )}
          </button>
        </form>
      </div>
    </div>
  );
};

