/// JavaScript that fills in web platform features Ladybird is missing and that real sites depend on. Every view runs
/// it as soon as a page starts loading (and again as its URL, title and loading state change, since an early run can
/// land in the document being replaced). Each part checks for the real feature first, so it steps aside once the
/// engine has it.
///
/// ImageBitmapRenderingContext (`canvas.getContext('bitmaprenderer')`): Ladybird returns null. Flutter web's
/// CanvasKit renderer draws each frame into an offscreen canvas and shows it on the page with
/// `transferFromImageBitmap`, so every Flutter web app stays blank, and throws "Cannot access property "toString"
/// on null" from its rasterizer. This stand-in shows the bitmap through the canvas's 2D context instead.
const pageCompatScript = r'''
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
})();
''';
