import React, { useState, useEffect } from 'react';
import { WebsiteView } from './components/WebsiteView';
import { MobileAppView } from './components/MobileAppView';
import { DesktopBlockedView } from './components/DesktopBlockedView';
import { TestPanel } from './components/TestPanel';

export function isMobileOrTablet(): boolean {
  if (typeof window === 'undefined' || typeof navigator === 'undefined') return true;

  const ua = (navigator.userAgent || navigator.vendor || (window as any).opera || '').toLowerCase();

  // 1. Mobile & tablet user agents
  const isMobileUA = /android|webos|iphone|ipad|ipod|blackberry|iemobile|opera mini|mobile|tablet|silk|kindle/i.test(ua);
  if (isMobileUA) return true;

  // 2. Modern iPadOS (pretends to be Macintosh desktop Safari, but has touch points)
  const isIPadOS = /macintosh/i.test(ua) && navigator.maxTouchPoints > 1;
  if (isIPadOS) return true;

  // 3. Touch device with phone/tablet screen bounds
  const isTouchDevice = 'ontouchstart' in window || navigator.maxTouchPoints > 0;
  const isMobileScreen = window.innerWidth <= 1024 || window.innerHeight <= 1024;
  if (isTouchDevice && isMobileScreen) return true;

  return false;
}

export const App: React.FC = () => {
  const [isAllowedDevice, setIsAllowedDevice] = useState<boolean>(() => isMobileOrTablet());

  const [initialPairPayload] = useState<string | null>(() => {
    if (typeof window === 'undefined') return null;
    const href = window.location.href;
    if (href.includes('d=') && href.includes('k=') && href.includes('sid=')) {
      return href;
    }
    return null;
  });

  const [view, setView] = useState<'website' | 'app'>(() => {
    if (typeof window === 'undefined') return 'website';
    const isStandalone =
      window.matchMedia('(display-mode: standalone)').matches ||
      Boolean((window.navigator as unknown as { standalone?: boolean }).standalone);
    const hash = window.location.hash.toLowerCase();
    const href = window.location.href;

    if (isStandalone || hash.includes('#/app') || hash.includes('#app') || (href.includes('d=') && href.includes('k='))) {
      return 'app';
    }
    return 'website';
  });

  useEffect(() => {
    const handleResize = () => {
      setIsAllowedDevice(isMobileOrTablet());
    };

    const handleHashChange = () => {
      const hash = window.location.hash.toLowerCase();
      if (hash.includes('#/app') || hash.includes('#app')) {
        setView('app');
      } else if (hash === '' || hash === '#' || hash.includes('#/') || hash.includes('#specs')) {
        setView('website');
      }
    };

    window.addEventListener('resize', handleResize);
    window.addEventListener('hashchange', handleHashChange);
    return () => {
      window.removeEventListener('resize', handleResize);
      window.removeEventListener('hashchange', handleHashChange);
    };
  }, []);

  // Gating: Only mobile devices and tablets are allowed to view Distee. The test panel is
  // rendered alongside every view so judges can reach it from a laptop as well.
  if (!isAllowedDevice) {
    return (
      <>
        <DesktopBlockedView />
        <TestPanel />
      </>
    );
  }

  const handleLaunchApp = () => {
    setView('app');
    window.location.hash = '#/app';
  };

  const handleBackToWebsite = () => {
    setView('website');
    window.location.hash = '#/';
  };

  if (view === 'app') {
    return (
      <>
        <MobileAppView
          onBackToWebsite={handleBackToWebsite}
          initialPairPayload={initialPairPayload}
        />
        <TestPanel />
      </>
    );
  }

  return (
    <>
      <WebsiteView onLaunchApp={handleLaunchApp} />
      <TestPanel />
    </>
  );
};

export default App;
