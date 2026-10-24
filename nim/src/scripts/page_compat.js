
(() => {
  if (window.__webbyCompat) return;
  window.__webbyCompat = true;

  if (typeof HTMLCanvasElement !== 'undefined' && !('ImageBitmapRenderingContext' in window)) {
    const getContext = HTMLCanvasElement.prototype.getContext;
    const contexts = new WeakMap();
    class ImageBitmapRenderingContext {
      constructor(canvas, context2d) {
        Object.defineProperty(this, '__canvas', { value: canvas });
        Object.defineProperty(this, '__context2d', { value: context2d });
      }
      get canvas() { return this.__canvas; }
      transferFromImageBitmap(bitmap) {
        const canvas = this.__canvas, context = this.__context2d;
        if (bitmap == null) {
          context.clearRect(0, 0, canvas.width, canvas.height);
          return;
        }
        if (!(bitmap instanceof ImageBitmap)) throw new TypeError('transferFromImageBitmap: not an ImageBitmap');
        // The canvas takes the bitmap's size, as it does with a real bitmap renderer.
        if (canvas.width !== bitmap.width) canvas.width = bitmap.width;
        if (canvas.height !== bitmap.height) canvas.height = bitmap.height;
        context.clearRect(0, 0, canvas.width, canvas.height);
        context.drawImage(bitmap, 0, 0);
        bitmap.close();
      }
    }
    HTMLCanvasElement.prototype.getContext = function (type, options) {
      if (String(type) !== 'bitmaprenderer') return getContext.apply(this, arguments);
      let context = contexts.get(this);
      if (!context) {
        const context2d = getContext.call(this, '2d');
        if (!context2d) return null;
        context = new ImageBitmapRenderingContext(this, context2d);
        contexts.set(this, context);
      }
      return context;
    };
  }

  // Flutter web's CanvasKit renderer draws each frame into a WebGL OffscreenCanvas and then awaits
  // createImageBitmap(canvas) before putting it on screen. Ladybird settles that promise in a later task, after the
  // rendering update that ran the frame, so every frame (a scroll, say) shows up one update late.
  // transferToImageBitmap hands over the same pixels at once; Flutter clears and redraws the whole canvas before each
  // bitmap it takes, so moving the pixels out instead of copying them loses nothing.
  if (typeof OffscreenCanvas !== 'undefined' && typeof window.createImageBitmap === 'function') {
    const glCanvases = new WeakSet();
    const getContext = OffscreenCanvas.prototype.getContext;
    OffscreenCanvas.prototype.getContext = function (type, options) {
      const context = getContext.apply(this, arguments);
      if (context && /^webgl2?$/.test(String(type)) && !(options && options.preserveDrawingBuffer)) glCanvases.add(this);
      return context;
    };
    const createImageBitmap = window.createImageBitmap;
    window.createImageBitmap = function (source) {
      if (arguments.length === 1 && window._flutter && glCanvases.has(source)) {
        try {
          return Promise.resolve(source.transferToImageBitmap());
        } catch (e) {}
      }
      return createImageBitmap.apply(this, arguments);
    };
  }

  // Better still, Flutter can skip the offscreen canvas and draw straight into on-page WebGL canvases, as it does on
  // Safari and Firefox: no read back of every frame into WebContent and no copy into a 2D canvas, so a scroll reaches
  // the screen sooner. Flutter reads canvasKitForceMultiSurfaceRasterizer off the plain configuration object it gets
  // from _flutter.loader.load() (an empty one when the page passes none), so a default on Object.prototype turns it
  // on unless the page sets it itself.
  // A control tied to its form by a form="id" attribute loses that tie in Ladybird when it was cloned from a
  // <template>'s content and the form comes after it in the page: the clone registers its form attribute with the
  // template's document and adoption never moves it, so inserting the form later doesn't reach it. Its .form stays
  // null and its submit button does nothing (try.haxy.net's sign-up page renders its controls exactly so). Setting
  // the attribute again registers it with the page's document and finds the form, as a fixed engine would have.
  if (typeof HTMLFormElement !== 'undefined' && (() => {
    // Built node by node in the template's own document, as its parser would: innerHTML throws on pages that require
    // Trusted Types (YouTube), and that took every shim below down with it.
    const template = document.createElement('template');
    const content = template.content, doc = content.ownerDocument;
    const control = doc.createElement('input');
    control.setAttribute('form', '__webby_form_probe');
    const probeForm = doc.createElement('form');
    probeForm.id = '__webby_form_probe';
    content.append(control, probeForm);
    // The probe goes in the page for a moment, and its clones one at a time: inserted together, the control would
    // find the form already there.
    const parent = document.body || document.documentElement;
    if (!parent) return false;
    const box = parent.appendChild(document.createElement('div'));
    for (const node of Array.from(template.content.childNodes)) box.appendChild(node.cloneNode(true));
    const broken = box.firstChild.form === null;
    box.remove();
    return broken;
  })()) {
    const relink = () => {
      for (const el of document.querySelectorAll('[form]')) {
        if (el.form || !('form' in el)) continue;
        const id = el.getAttribute('form');
        if (document.getElementById(id) instanceof HTMLFormElement) el.setAttribute('form', id);
      }
    };
    const mayNeedRelink = (node) => node.nodeType === 1 &&
      (node.matches('[form], form[id]') || node.querySelector('[form], form[id]') !== null);
    new MutationObserver((records) => {
      if (records.some((record) => Array.from(record.addedNodes).some(mayNeedRelink))) relink();
    }).observe(document, { childList: true, subtree: true });
    // A click or Enter that submits reads the button's form right after the event, so catch any left over first.
    window.addEventListener('click', relink, true);
    window.addEventListener('keydown', (event) => { if (event.key === 'Enter') relink(); }, true);
    relink();
  }

  // Ladybird has no MediaRecorder. Pages that subclass it at the top of a module (`class extends MediaRecorder`, as
  // Jam's recorder.jam.dev does) die with a ReferenceError before they draw anything, even when they would check for
  // recording support and say it's missing. A stand-in that can be extended but records nothing lets them get there.
  if (typeof window.MediaRecorder === 'undefined' && typeof EventTarget !== 'undefined') {
    class MediaRecorder extends EventTarget {
      constructor() {
        super();
        throw new DOMException('MediaRecorder is not supported in this browser', 'NotSupportedError');
      }
      static isTypeSupported() { return false; }
      static get __webbyStandIn() { return true; }   // screen_capture.js replaces it where webby can record
    }
    Object.defineProperty(window, 'MediaRecorder', { value: MediaRecorder, writable: true, configurable: true });
  }

  // detectIncognito (a library Jam's recorder awaits before it submits a recording) tells engines apart by the
  // length of the RangeError message from (-1).toFixed(-1) and gives up on one it doesn't know, Ladybird's. Firefox's
  // wording makes it run its Firefox checks, which Ladybird passes.
  if ((() => { try { (-1).toFixed(-1); } catch (e) { return e instanceof RangeError && e.message.length !== 25; } })()) {
    const toFixed = Number.prototype.toFixed;
    Object.defineProperty(Number.prototype, 'toFixed', {
      value: {
        toFixed(digits) {
          try {
            return toFixed.call(this, digits);
          } catch (e) {
            if (!(e instanceof RangeError)) throw e;
            throw new RangeError(`precision ${Math.trunc(Number(digits))} out of range`);
          }
        },
      }.toFixed,
      writable: true,
      configurable: true,
    });
  }

  if (!('canvasKitForceMultiSurfaceRasterizer' in Object.prototype)) {
    Object.defineProperty(Object.prototype, 'canvasKitForceMultiSurfaceRasterizer', {
      get() { return true; },
      set(value) {
        Object.defineProperty(this, 'canvasKitForceMultiSurfaceRasterizer', { value, writable: true, enumerable: true, configurable: true });
      },
      configurable: true,
    });
  }
})();
