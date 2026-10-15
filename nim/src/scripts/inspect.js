
(() => {
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
  if (window.__webbyContextMenu) {
    window.__webbyContextMenu.act('inspect');
  } else if (window.eruda) {
    if (!window.eruda._isInit) window.eruda.init();
    window.eruda.show();
    window.eruda.show('elements');
  }
})();
