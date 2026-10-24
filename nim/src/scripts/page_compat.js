
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

  // React menus and dialogs (Radix UI, which bsky.app's repost and post menus use, and the kits built on it) make the
  // page behind them inert with body.style.pointerEvents = 'none' while they are open. pointer-events is inherited, so
  // in Ladybird that restyles every element of the page, once when the menu opens and once when it closes: 1.1 s each
  // on a Bluesky feed scrolled 400 posts down. The page gets the same behavior for the price of a few
  // getComputedStyle calls per click: body keeps its style (reading it back still says 'none'), and a click outside
  // the menu goes to <html> instead of the element under it, as hit testing finds it when body is pointer-events: none.
  // That's what the menu listens for to close itself. Inside means an element below body with pointer-events of its
  // own other than none, as the menu's content sets.
  if (typeof CSSStyleDeclaration !== 'undefined') {
    let owner = Object.getPrototypeOf(document.documentElement.style), accessor;
    while (owner && !(accessor = Object.getOwnPropertyDescriptor(owner, 'pointerEvents'))) owner = Object.getPrototypeOf(owner);
    if (accessor && accessor.get && accessor.set && accessor.configurable) {
      let inert = false;
      const isBodyStyle = (style) => document.body !== null && style === document.body.style;
      Object.defineProperty(owner, 'pointerEvents', {
        configurable: true,
        enumerable: accessor.enumerable,
        get() { return inert && isBodyStyle(this) ? 'none' : accessor.get.call(this); },
        set(value) {
          if (!isBodyStyle(this)) return accessor.set.call(this, value);
          const wasInert = inert;
          inert = String(value) === 'none';
          // Leaving inert puts back what the page saved before it set 'none', which the real style still has.
          if (!inert && !(wasInert && accessor.get.call(this) === String(value))) accessor.set.call(this, value);
        },
      });
      const hitTestable = (event) => {
        for (const node of event.composedPath()) {
          if (node === document.body || node === document.documentElement) return false;
          if (node.nodeType !== 1) continue;
          const own = node.style && node.style.pointerEvents;
          if (own) return own !== 'none';
          const parent = node.parentElement;
          if (!parent || parent === document.body) continue;
          const value = getComputedStyle(node).pointerEvents;
          if (value !== getComputedStyle(parent).pointerEvents) return value !== 'none';
        }
        return false;
      };
      for (const type of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu']) {
        window.addEventListener(type, (event) => {
          if (!inert || !event.isTrusted || hitTestable(event)) return;
          event.stopImmediatePropagation();
          event.preventDefault();
          const copy = new event.constructor(event.type, event);
          document.documentElement.dispatchEvent(copy);
        }, true);
      }
    }
  }

  // virtua, the list virtualizer behind Colibri's chat and member lists (and many React, Vue, Solid and Svelte apps),
  // gives its list container pointer-events: none while the list scrolls and takes it off when scrolling stops, to save
  // hover work. pointer-events is inherited, so in Ladybird each toggle restyles every row of the list: 250-350 ms on a
  // Colibri channel, several times while a space opens (the list scrolls itself to the newest message) and twice per
  // scroll gesture. The container is the element whose inline style has virtua's contain: size style; it never gets
  // the 'none', which only changes what the pointer hovers mid-scroll.
  if (typeof CSSStyleDeclaration !== 'undefined') {
    const proto = CSSStyleDeclaration.prototype;
    const getPropertyValue = proto.getPropertyValue, setProperty = proto.setProperty;
    const isVirtuaContainer = (style) => getPropertyValue.call(style, 'contain') === 'size style';
    proto.setProperty = function (name, value) {
      if (name === 'pointer-events' && String(value) === 'none' && isVirtuaContainer(this)) return;
      return setProperty.apply(this, arguments);
    };
    let owner = Object.getPrototypeOf(document.documentElement.style), accessor;
    while (owner && !(accessor = Object.getOwnPropertyDescriptor(owner, 'pointerEvents'))) owner = Object.getPrototypeOf(owner);
    if (accessor && accessor.set && accessor.configurable) {
      Object.defineProperty(owner, 'pointerEvents', {
        configurable: true,
        enumerable: accessor.enumerable,
        get: accessor.get,
        set(value) {
          if (String(value) === 'none' && isVirtuaContainer(this)) return;
          accessor.set.call(this, value);
        },
      });
    }
  }

  // The same menus lock the page's scrolling with react-remove-scroll, which blocks wheel and touch scrolling itself
  // and also sets body[data-scroll-locked], a style that gives body overflow: hidden. Body's overflow is the
  // viewport's, so Ladybird lays the whole page out again for it (1.2 s on that feed) and again when the menu closes.
  // The wheel and touch blocking is what keeps the page still; without the attribute the menu opens without the
  // relayout. The library reads the attribute back only to count nested locks, and an absent one counts as none.
  if (typeof Element !== 'undefined') {
    const setAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      if (typeof name === 'string' && name.length === 18 && this === document.body && name.toLowerCase() === 'data-scroll-locked') return;
      return setAttribute.apply(this, arguments);
    };
  }

  // And they put a focus guard (an invisible position: fixed span) at the very start of body. Ladybird adds a box
  // ahead of the page's own content by building body's whole layout tree again (1-2.4 s on that feed), where one
  // added at the end slots in. The guards only catch Tab at the edges of the page, so the first goes at the end too.
  if (typeof Element !== 'undefined') {
    const insertAdjacentElement = Element.prototype.insertAdjacentElement;
    Element.prototype.insertAdjacentElement = function (where, element) {
      if (this === document.body && element instanceof Element && element.hasAttribute('data-radix-focus-guard')
          && String(where).toLowerCase() === 'afterbegin') where = 'beforeend';
      return insertAdjacentElement.call(this, where, element);
    };
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
