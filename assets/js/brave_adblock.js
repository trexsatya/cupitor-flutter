// Loaded by the native Brave engine at document start in every WebView frame.
(function () {
  'use strict';
  if (window.__cupitorBraveInstalled) return;
  const promptNative = window.prompt;
  const pageURL = /^https?:/.test(location.href) ? location.href : (document.referrer || location.href);
  function query(value) {
    try {
      value.url = pageURL;
      const message = JSON.stringify(value);
      const result = window.CupitorBraveNative
        ? window.CupitorBraveNative.query(message)
        : promptNative.call(window, '__cupitor_brave_v1__', message);
      return result ? JSON.parse(result) : null;
    } catch (_) { return null; }
  }
  const status = query({op: 'status'}) || window.__cupitorBraveBootstrap;
  delete window.__cupitorBraveBootstrap;
  if (!status || !status.ready) return;
  window.__cupitorBraveManaged = true;
  if (status.enabled === false) return;
  window.__cupitorBraveInstalled = true;
  window.__cupitorBraveActive = true;
  // WebKit content rules use top-frame context. Ask the same native matcher
  // for fetch/XHR in each frame too, so embedded YouTube gets its own source
  // domain and maintained exceptions. Android also retains native interception.
  const realFetch = window.fetch;
  function decision(target, method) {
    try {
      const absolute = new URL(target, pageURL);
      if (!/^https?:$/.test(absolute.protocol)) return null;
      return query({op:'network', target:absolute.href, type:'xmlhttprequest', method:method || 'GET'});
    } catch (_) { return null; }
  }
  if (typeof realFetch === 'function') window.fetch = function (input, init) {
    const target = typeof input === 'string' ? input : input?.url || String(input);
    const match = decision(target, init?.method || input?.method);
    if (match?.blocked) {
      if (match.redirect?.startsWith('data:') && match.redirect.includes(';base64,')) {
        const marker = match.redirect.indexOf(';base64,');
        const type = match.redirect.slice(5, marker).split(';')[0];
        const data = Uint8Array.from(atob(match.redirect.slice(marker + 8)), c => c.charCodeAt(0));
        return Promise.resolve(new Response(data, {status:200, headers:{'Content-Type':type}}));
      }
      return Promise.reject(new TypeError('Failed to fetch'));
    }
    if (match?.rewritten) {
      input = typeof Request !== 'undefined' && input instanceof Request ? new Request(match.rewritten, input) : match.rewritten;
    }
    return realFetch.call(this, input, init);
  };
  if (window.XMLHttpRequest) {
    const open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, target, ...rest) {
      const match = decision(target, method);
      if (match?.blocked) return open.call(this, 'GET', match.redirect || 'data:text/plain,', ...rest);
      return open.call(this, method, match?.rewritten || target, ...rest);
    };
  }
  const scriptletGlobals = new Map();
  let preloaded = false, preloadedPage = null;
  /* CUPITOR_BRAVE_SCRIPTLETS */
  const page = query({op: 'page', scriptlets: !preloaded}) || preloadedPage || {};
  if (!preloaded && page.js) { try { eval(page.js); } catch (_) {} }
  const selectors = new Set(page.selectors || []);
  const seenClasses = new Set(), seenIds = new Set();
  let timer = null, style;
  const inline = new Map();
  function render() {
    const root = document.documentElement;
    if (!root) return;
    if (!style) { style = document.createElement('style'); style.id = 'cupitor-brave-cosmetics'; }
    const content = Array.from(selectors).map(s => s + ' {display:none!important;}').join('\n');
    if (style.textContent !== content) style.textContent = content;
    if (!style.isConnected) root.appendChild(style);
    // A strict style-src policy can reject a stylesheet created in the page.
    // CSSOM property writes still allow the native-selected selectors to hide
    // ads. Restore nodes when a dynamic page reuses them for ordinary content.
    if (style.sheet == null) {
      const hidden = new Set();
      for (const selector of selectors) {
        try { for (const node of document.querySelectorAll(selector)) hidden.add(node); } catch (_) {}
      }
      for (const [node, previous] of inline) {
        if (!hidden.has(node)) {
          if (node.style.getPropertyValue('display') === 'none' && node.style.getPropertyPriority('display') === 'important') {
            if (previous.value) node.style.setProperty('display', previous.value, previous.priority);
            else node.style.removeProperty('display');
          }
          inline.delete(node);
        }
      }
      for (const node of hidden) {
        if (!inline.has(node)) inline.set(node, {value:node.style.getPropertyValue('display'), priority:node.style.getPropertyPriority('display')});
        node.style.setProperty('display', 'none', 'important');
      }
    }
  }
  function update() {
    timer = null;
    if (!page.generichide) {
      const classes = [], ids = [];
      let more = false;
      for (const element of document.querySelectorAll('[class],[id]')) {
        if (element.id && !seenIds.has(element.id)) {
          if (ids.length < 256) { seenIds.add(element.id); ids.push(element.id); }
          else more = true;
        }
        for (const name of element.classList) {
          if (!seenClasses.has(name)) {
            if (classes.length < 256) { seenClasses.add(name); classes.push(name); }
            else more = true;
          }
        }
      }
      if (classes.length || ids.length) {
        const result = query({op:'selectors', classes, ids});
        for (const selector of result?.selectors || []) selectors.add(selector);
      }
      if (more && timer == null) timer = setTimeout(update, 200);
    }
    render();
  }
  new MutationObserver(() => {
    if (timer == null) timer = setTimeout(update, 200);
  }).observe(document, {subtree:true, childList:true, attributes:true, attributeFilter:['class','id']});
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', update, {once:true});
  else update();
  render();
})();
