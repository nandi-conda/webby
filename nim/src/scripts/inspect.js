// Opens the devtools (eruda) in the page: on the given panel, or on the right-clicked element (the menu's "Inspect").
// Webby hears whether the devtools are open and on which panel, and runs this again after a reload or navigation, so
// they stay open like a browser's own devtools.
((tool, select) => {
  if (!window.eruda) {
    // eruda is a UMD bundle: hide any AMD/CommonJS loader the page has so it lands on window.eruda. It throws on pages
    // without storage (opaque origins); there is nothing to inspect with then.
    try {
      (function (define, module, exports) {
$erudaSource
      }).call(window);
    } catch (e) {
      return;
    }
  }
  const eruda = window.eruda;
  if (!eruda) return;
  const open = () => {
    if (!eruda._isInit) eruda.init();
    if (!window.__webbyDevtools) {
      window.__webbyDevtools = true;
      // Pages sometimes replace window.prompt; use a pristine one from a fresh frame if so.
      let host = window;
      if (!/\[native code\]/.test(Function.prototype.toString.call(window.prompt))) {
        try {
          const frame = document.createElement('iframe');
          frame.style.display = 'none';
          document.documentElement.appendChild(frame);
          host = frame.contentWindow;
        } catch (e) {}
      }
      const prompt = host.prompt;
      // Sent from a task of its own: eruda fires these while webby's own script call is still running.
      const send = (message) => setTimeout(() => { try { prompt.call(host, $prefix + JSON.stringify(message)); } catch (e) {} });
      const devTools = eruda._devTools;
      if (devTools && devTools.on) {
        devTools.on('show', () => send({ type: 'devtools', open: true, tool: devTools._curTool || '' }));
        devTools.on('hide', () => send({ type: 'devtools', open: false }));
        devTools.on('showTool', (name) => { if (devTools._isShow) send({ type: 'devtools', open: true, tool: name }); });
      }
    }
    if (select && window.__webbyContextMenu) {
      window.__webbyContextMenu.act('inspect');
    } else {
      eruda.show();
      try { eruda.show(tool || 'elements'); } catch (e) { eruda.show('elements'); }
    }
  };
  // Never talk to webby (prompt) while the page is still being parsed: that can wedge Ladybird's loading.
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', open, { once: true });
  else open();
})($tool, $select);
