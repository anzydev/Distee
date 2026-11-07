import React, { useState, useEffect, useRef } from 'react';
import { X, Camera, QrCode, CheckCircle2, AlertCircle, Loader2 } from 'lucide-react';
import jsQR from 'jsqr';
import { parseQRPayload, executePairingHandshake, QRPayload } from '../services/pairing';
import { PairedMac } from '../storage/storage';

interface PairingModalProps {
  initialPayload?: string | null;
  onClose: () => void;
  onSuccess: (mac: PairedMac) => void;
}

export const PairingModal: React.FC<PairingModalProps> = ({ initialPayload, onClose, onSuccess }) => {
  const [step, setStep] = useState<'scan' | 'handshake' | 'success' | 'error'>(
    initialPayload ? 'handshake' : 'scan'
  );
  const [manualInput, setManualInput] = useState('');
  const [confCode, setConfCode] = useState<string | null>(null);
  const [phoneLabel, setPhoneLabel] = useState('My Phone');
  const phoneLabelRef = useRef('My Phone');
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [cameraError, setCameraError] = useState<string | null>(null);

  const videoRef = useRef<HTMLVideoElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const scanningRef = useRef<boolean>(true);
  const handshakeStartedRef = useRef<boolean>(false);

  // If initial payload passed from URL query
  useEffect(() => {
    if (initialPayload) {
      try {
        const qr = parseQRPayload(initialPayload);
        startHandshake(qr);
      } catch (err: any) {
        setStep('error');
        setErrorMessage(err.message);
      }
    } else {
      startCamera();
    }

    return () => {
      stopCamera();
    };
  }, [initialPayload]);

  const startCamera = async () => {
    try {
      setCameraError(null);
      scanningRef.current = true;
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment' },
      });
      streamRef.current = stream;
      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        videoRef.current.setAttribute('playsinline', 'true');
        videoRef.current.play();
        requestAnimationFrame(tick);
      }
    } catch (err: any) {
      setCameraError('Camera access denied or unavailable. You can paste the pairing link below.');
    }
  };

  const stopCamera = () => {
    scanningRef.current = false;
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
    }
  };

  const tick = () => {
    if (!scanningRef.current) return;

    const video = videoRef.current;
    const canvas = canvasRef.current;

    if (video && canvas && video.readyState === video.HAVE_ENOUGH_DATA) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      const ctx = canvas.getContext('2d');
      if (ctx) {
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const code = jsQR(imageData.data, imageData.width, imageData.height, {
          inversionAttempts: 'dontInvert',
        });

        if (code && code.data) {
          try {
            const qr = parseQRPayload(code.data);
            stopCamera();
            startHandshake(qr);
            return;
          } catch {}
        }
      }
    }
    requestAnimationFrame(tick);
  };

  const startHandshake = async (qr: QRPayload) => {
    if (handshakeStartedRef.current) return;
    handshakeStartedRef.current = true;
    setStep('handshake');
    setErrorMessage(null);

    try {
      const result = await executePairingHandshake(
        qr,
        phoneLabelRef.current,
        (derivedCode) => {
          setConfCode(derivedCode);
        },
        30000
      );

      setStep('success');
      setTimeout(() => {
        onSuccess(result.mac);
      }, 1500);
    } catch (err: any) {
      handshakeStartedRef.current = false;
      setStep('error');
      setErrorMessage(err.message || 'Pairing failed');
    }
  };

  const handleManualSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!manualInput) return;
    try {
      const qr = parseQRPayload(manualInput);
      stopCamera();
      startHandshake(qr);
    } catch (err: any) {
      setErrorMessage(err.message);
    }
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
        {/* Close Button */}
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

        {/* STEP 1: SCANNER */}
        {step === 'scan' && (
          <div>
            <div style={{ textAlign: 'center', marginBottom: '18px' }}>
              <div style={{ fontSize: '20px', fontWeight: 600, color: '#f8fafc' }}>
                Scan Mac QR Code
              </div>
              <div style={{ fontSize: '13px', color: '#94a3b8', marginTop: '4px' }}>
                Point camera at the QR code displayed in Distee on your Mac
              </div>
            </div>

            {/* Video Viewport */}
            <div style={{
              width: '100%',
              height: '260px',
              borderRadius: '16px',
              overflow: 'hidden',
              background: '#020617',
              position: 'relative',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              border: '2px solid rgba(99, 102, 241, 0.4)'
            }}>
              <video
                ref={videoRef}
                style={{ width: '100%', height: '100%', objectFit: 'cover' }}
              />
              <canvas ref={canvasRef} style={{ display: 'none' }} />

              {/* Target box */}
              <div style={{
                position: 'absolute',
                width: '180px',
                height: '180px',
                border: '2px dashed #6366f1',
                borderRadius: '12px',
                pointerEvents: 'none'
              }} />

              {cameraError && (
                <div style={{ position: 'absolute', padding: '16px', textAlign: 'center', color: '#f87171', fontSize: '13px' }}>
                  <AlertCircle size={24} style={{ margin: '0 auto 8px' }} />
                  {cameraError}
                </div>
              )}
            </div>

            {/* Manual input fallback */}
            <form onSubmit={handleManualSubmit} style={{ marginTop: '16px' }}>
              <div style={{ fontSize: '12px', color: '#64748b', marginBottom: '6px' }}>
                Or paste pairing URL manually:
              </div>
              <div style={{ display: 'flex', gap: '8px' }}>
                <input
                  type="text"
                  placeholder="distee://pair?v=1&..."
                  value={manualInput}
                  onChange={(e) => setManualInput(e.target.value)}
                  style={{
                    flex: 1,
                    background: 'rgba(0,0,0,0.3)',
                    border: '1px solid rgba(255,255,255,0.1)',
                    borderRadius: '10px',
                    padding: '10px 12px',
                    color: '#fff',
                    fontSize: '16px' // >=16px stops iOS Safari zooming the page on focus
                  }}
                />
                <button
                  type="submit"
                  style={{
                    background: '#4f46e5',
                    border: 'none',
                    borderRadius: '10px',
                    padding: '0 16px',
                    color: '#fff',
                    fontWeight: 600,
                    cursor: 'pointer'
                  }}
                >
                  Pair
                </button>
              </div>
            </form>
          </div>
        )}

        {/* STEP 2: HANDSHAKE & CONFIRMATION CODE */}
        {step === 'handshake' && (
          <div style={{ textAlign: 'center', padding: '16px 0' }}>
            <Loader2 size={40} style={{ color: '#818cf8', margin: '0 auto 16px', animation: 'spin 1s linear infinite' }} />
            <div style={{ fontSize: '20px', fontWeight: 600, color: '#f8fafc' }}>
              Pairing with Mac...
            </div>
            <div style={{ fontSize: '14px', color: '#94a3b8', marginTop: '6px' }}>
              Exchanging encrypted device keys
            </div>

            {confCode && (
              <div style={{
                margin: '24px 0',
                padding: '18px',
                background: 'rgba(99, 102, 241, 0.1)',
                border: '1px solid rgba(99, 102, 241, 0.25)',
                borderRadius: '16px'
              }}>
                <div style={{ fontSize: '12px', textTransform: 'uppercase', letterSpacing: '0.05em', color: '#a5b4fc', marginBottom: '6px' }}>
                  Confirmation Code
                </div>
                <div style={{ fontSize: '36px', fontWeight: 700, letterSpacing: '0.15em', color: '#ffffff', fontFamily: 'monospace' }}>
                  {confCode.slice(0, 3)} {confCode.slice(3)}
                </div>
                <div style={{ fontSize: '12px', color: '#94a3b8', marginTop: '6px' }}>
                  Verify this code matches the code on your Mac screen
                </div>
              </div>
            )}
          </div>
        )}

        {/* STEP 3: SUCCESS */}
        {step === 'success' && (
          <div style={{ textAlign: 'center', padding: '24px 0' }}>
            <CheckCircle2 size={54} style={{ color: '#22c55e', margin: '0 auto 16px' }} />
            <div style={{ fontSize: '22px', fontWeight: 600, color: '#f8fafc' }}>
              Pairing Successful!
            </div>
            <div style={{ fontSize: '14px', color: '#94a3b8', marginTop: '6px' }}>
              Your Mac is now authorized and ready for remote locking.
            </div>
          </div>
        )}

        {/* STEP 4: ERROR */}
        {step === 'error' && (
          <div style={{ textAlign: 'center', padding: '16px 0' }}>
            <AlertCircle size={48} style={{ color: '#ef4444', margin: '0 auto 14px' }} />
            <div style={{ fontSize: '20px', fontWeight: 600, color: '#f8fafc' }}>
              Pairing Failed
            </div>
            <div style={{ fontSize: '14px', color: '#f87171', marginTop: '8px', padding: '12px', background: 'rgba(239, 68, 68, 0.1)', borderRadius: '12px' }}>
              {errorMessage || 'Unknown error during pairing'}
            </div>
            <button
              onClick={() => {
                setStep('scan');
                startCamera();
              }}
              style={{
                marginTop: '20px',
                background: '#4f46e5',
                border: 'none',
                borderRadius: '12px',
                padding: '12px 24px',
                color: '#fff',
                fontWeight: 600,
                cursor: 'pointer'
              }}
            >
              Try Again
            </button>
          </div>
        )}
      </div>

      <style>{`
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
};

