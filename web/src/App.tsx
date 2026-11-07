import React, { useState, useEffect } from 'react';
import { Shield, Plus, Settings, Laptop, Lock } from 'lucide-react';
import { getPairedMacs, removePairedMac, PairedMac } from './storage/storage';
import { MacCard } from './components/MacCard';
import { PairingModal } from './components/PairingModal';
import { SettingsModal } from './components/SettingsModal';
import { transports } from './services/transport';

export const App: React.FC = () => {
  const [macs, setMacs] = useState<PairedMac[]>([]);
  const [showPairModal, setShowPairModal] = useState(false);
  const [showSettingsModal, setShowSettingsModal] = useState(false);
  const [initialPairPayload, setInitialPairPayload] = useState<string | null>(null);

  useEffect(() => {
    const existing = getPairedMacs();
    setMacs(existing);

    // Check for query parameters in URL (e.g. when camera opens link directly)
    const fullUrl = window.location.href;
    if (fullUrl.includes('d=') && fullUrl.includes('k=') && fullUrl.includes('sid=')) {
      const match = fullUrl.match(/[?&]d=([a-z0-9]{16})/i);
      const targetId = match ? match[1].toLowerCase() : null;
      const isAlreadyPaired = targetId && existing.some(m => m.deviceId.toLowerCase() === targetId);

      if (isAlreadyPaired) {
        // Mac is already paired on this phone; remove hash parameters cleanly
        try {
          window.location.hash = '';
          window.history.replaceState({}, document.title, window.location.origin + window.location.pathname);
        } catch {}
      } else {
        setInitialPairPayload(fullUrl);
        setShowPairModal(true);
      }
    }
  }, []);

  const handlePairSuccess = (newMac: PairedMac) => {
    setShowPairModal(false);
    setInitialPairPayload(null);
    setMacs(getPairedMacs());
    // Clear URL query parameters cleanly from address bar and hash
    try {
      window.location.hash = '';
      window.history.replaceState({}, document.title, window.location.origin + window.location.pathname);
    } catch {}
  };

  const handleUnpair = async (deviceId: string) => {
    const transport = transports.getOrCreate(deviceId);
    let acked = false;
    try {
      acked = await transport.sendUnpairCommand();
    } catch {
      acked = false;
    }
    if (!acked) {
      const force = window.confirm(
        'The Mac did not confirm the unpair (it may be offline). Remove it from this phone anyway? You will also need to choose Unpair on the Mac itself before it can pair again.'
      );
      if (!force) return;
    }
    transports.remove(deviceId);
    removePairedMac(deviceId);
    setMacs(getPairedMacs());
  };

  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
      {/* Top Navigation Bar */}
      <header style={{
        position: 'sticky',
        top: 0,
        zIndex: 30,
        background: 'rgba(9, 13, 22, 0.85)',
        backdropFilter: 'blur(16px)',
        WebkitBackdropFilter: 'blur(16px)',
        borderBottom: '1px solid rgba(255, 255, 255, 0.08)',
        padding: '14px 20px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between'
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <div style={{
            width: '38px',
            height: '38px',
            borderRadius: '10px',
            background: 'linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: '#fff',
            boxShadow: '0 4px 12px rgba(99, 102, 241, 0.35)'
          }}>
            <Shield size={20} />
          </div>
          <div>
            <span style={{ fontSize: '18px', fontWeight: 700, color: '#f8fafc', letterSpacing: '-0.02em' }}>
              Distee
            </span>
            <span style={{ fontSize: '11px', color: '#818cf8', display: 'block', fontWeight: 500, lineHeight: 1 }}>
              Remote Lock
            </span>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <button
            onClick={() => {
              setInitialPairPayload(null);
              setShowPairModal(true);
            }}
            style={{
              background: 'rgba(99, 102, 241, 0.15)',
              border: '1px solid rgba(99, 102, 241, 0.3)',
              color: '#a5b4fc',
              padding: '8px 14px',
              borderRadius: '10px',
              fontSize: '13px',
              fontWeight: 600,
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              cursor: 'pointer'
            }}
          >
            <Plus size={16} />
            <span>Add Mac</span>
          </button>

          <button
            onClick={() => setShowSettingsModal(true)}
            style={{
              background: 'transparent',
              border: 'none',
              color: '#94a3b8',
              padding: '8px',
              borderRadius: '8px',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center'
            }}
          >
            <Settings size={20} />
          </button>
        </div>
      </header>

      {/* Main Content Area */}
      <main style={{ flex: 1, padding: '20px 16px', maxWidth: '560px', width: '100%', margin: '0 auto', boxSizing: 'border-box' }}>
        {macs.length === 0 ? (
          /* Empty State */
          <div style={{
            textAlign: 'center',
            padding: '60px 20px',
            background: 'rgba(15, 23, 42, 0.5)',
            borderRadius: '24px',
            border: '1px dashed rgba(255, 255, 255, 0.12)',
            marginTop: '20px'
          }}>
            <div style={{
              width: '72px',
              height: '72px',
              borderRadius: '20px',
              background: 'rgba(99, 102, 241, 0.12)',
              color: '#818cf8',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              margin: '0 auto 20px'
            }}>
              <Laptop size={36} />
            </div>

            <div style={{ fontSize: '22px', fontWeight: 700, color: '#f8fafc', marginBottom: '8px' }}>
              No Macs Paired Yet
            </div>

            <div style={{ fontSize: '14px', color: '#94a3b8', maxWidth: '340px', margin: '0 auto 24px', lineHeight: 1.5 }}>
              Pair your Mac by scanning the 120-second QR code generated in the Distee Mac application.
            </div>

            <button
              onClick={() => {
                setInitialPairPayload(null);
                setShowPairModal(true);
              }}
              style={{
                background: 'linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%)',
                boxShadow: '0 4px 18px -2px rgba(99, 102, 241, 0.45)',
                color: '#fff',
                border: 'none',
                borderRadius: '14px',
                padding: '14px 28px',
                fontSize: '15px',
                fontWeight: 600,
                cursor: 'pointer',
                display: 'inline-flex',
                alignItems: 'center',
                gap: '8px'
              }}
            >
              <Plus size={18} />
              <span>Pair a Mac Now</span>
            </button>
          </div>
        ) : (
          /* Paired Macs List */
          <div style={{ display: 'flex', flexDirection: 'column', gap: '18px' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 4px' }}>
              <div style={{ fontSize: '14px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: '#94a3b8' }}>
                Your Macs ({macs.length})
              </div>
            </div>

            {macs.map((mac) => (
              <MacCard key={mac.deviceId} mac={mac} onUnpair={handleUnpair} />
            ))}
          </div>
        )}
      </main>

      {/* Footer Info */}
      <footer style={{ textAlign: 'center', padding: '24px 16px', fontSize: '12px', color: '#64748b' }}>
        Distee — ₹0 Infrastructure Remote Mac Locking System • End-to-End Encrypted
      </footer>

      {/* Modals */}
      {showPairModal && (
        <PairingModal
          initialPayload={initialPairPayload}
          onClose={() => {
            setShowPairModal(false);
            setInitialPairPayload(null);
            // Drop the pairing secret from the address bar so a refresh cannot re-trigger it.
            if (window.location.hash || window.location.search) {
              window.history.replaceState({}, document.title, window.location.pathname);
            }
          }}
          onSuccess={handlePairSuccess}
        />
      )}

      {showSettingsModal && (
        <SettingsModal onClose={() => setShowSettingsModal(false)} />
      )}
    </div>
  );
};
export default App;

