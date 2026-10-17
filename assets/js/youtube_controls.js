// Installed at document start in dialog1, including its cross-origin frames.
(function () {
  'use strict';
  const stateMessage = 'cupitor:youtube-controls';
  const readyMessage = 'cupitor:youtube-controls-ready';
  const hiddenClass = 'cupitor-youtube-controls-hidden';
  const shownClass = 'cupitor-youtube-controls-shown';

  function youtubeOrigin(value) {
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && [
        'youtube.com', 'www.youtube.com', 'm.youtube.com',
        'youtube-nocookie.com', 'www.youtube-nocookie.com'
      ].includes(url.hostname) && url.port === '';
    } catch (_) { return false; }
  }

  if (window === window.top) {
    if (window.CupitorYouTubeControls) return;
    let visible = true;
    let controlled = false;
    const frameOrigins = new WeakMap();
    const frames = () => Array.from(document.querySelectorAll('iframe'));
    function send(frame, origin) {
      if (frame.contentWindow && youtubeOrigin(origin)) {
        frame.contentWindow.postMessage({type: stateMessage, visible, controlled}, origin);
      }
    }
    window.addEventListener('message', function (event) {
      if (!event.data || event.data.type !== readyMessage ||
          !youtubeOrigin(event.origin)) return;
      const frame = frames().find(frame => frame.contentWindow === event.source);
      if (!frame) return;
      frameOrigins.set(frame.contentWindow, event.origin);
      send(frame, event.origin);
    });
    window.CupitorYouTubeControls = Object.freeze({
      get visible() { return visible; },
      setVisible(value) {
        if (typeof value !== 'boolean') throw new TypeError('visible must be a boolean');
        visible = value;
        controlled = true;
        for (const frame of frames()) {
          let origin = frameOrigins.get(frame.contentWindow);
          if (!origin) {
            try { origin = new URL(frame.src, location.href).origin; } catch (_) {}
          }
          send(frame, origin);
        }
        window.dispatchEvent(new CustomEvent('cupitorYouTubeControlsChanged', {
          detail: {visible}
        }));
      }
    });
    return;
  }

  // Only YouTube embeds receive CSS. Other frames and full YouTube pages
  // keep their normal appearance, even though the script runs in all frames.
  if (!youtubeOrigin(location.href) || !location.pathname.startsWith('/embed/')) return;
  if (window.__cupitorYouTubeControlsInstalled) return;
  window.__cupitorYouTubeControlsInstalled = true;
  let visible = true;
  let controlled = false;
  const style = document.createElement('style');
  style.id = 'cupitor-youtube-controls-style';
  style.textContent = [
    '.ytp-chrome-top', '.ytp-chrome-bottom',
    '.ytp-gradient-top', '.ytp-gradient-bottom',
    '.ytp-large-play-button', '.ytp-pause-overlay',
    '.ytp-watermark', '.ytp-cards-button', '.ytp-ce-element',
    '.ytp-endscreen-content', '.ytp-settings-menu', '.ytp-tooltip'
  ].map(selector => 'html.' + hiddenClass + ' ' + selector).join(',\n') +
    ' { visibility: hidden !important; opacity: 0 !important; pointer-events: none !important; }' +
    ['.ytp-chrome-top', '.ytp-chrome-bottom', '.ytp-gradient-top', '.ytp-gradient-bottom']
      .map(selector => 'html.' + shownClass + ' ' + selector).join(',\n') +
    ' { visibility: visible !important; opacity: 1 !important; pointer-events: auto !important; }';
  let observedRoot;
  const observer = new MutationObserver(apply);
  function apply() {
    const root = document.documentElement;
    if (!root) return;
    if (!style.isConnected) root.appendChild(style);
    if (root.classList.contains(hiddenClass) !== !visible) {
      root.classList.toggle(hiddenClass, !visible);
    }
    if (root.classList.contains(shownClass) !== (controlled && visible)) {
      root.classList.toggle(shownClass, controlled && visible);
    }
    if (observedRoot !== root) {
      observedRoot = root;
      observer.observe(root, {attributes: true, attributeFilter: ['class']});
    }
  }
  observer.observe(document, {childList: true, subtree: true});
  window.addEventListener('message', function (event) {
    if (event.source !== window.parent || !event.data ||
        event.data.type !== stateMessage || typeof event.data.visible !== 'boolean') return;
    visible = event.data.visible;
    controlled = event.data.controlled === true;
    apply();
  });

  apply();
  // The parent replies with its current state. This also covers replacement
  // iframes and video changes that navigate the iframe to a new document.
  window.parent.postMessage({type: readyMessage}, '*');
})();
