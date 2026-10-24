
(() => {
  if (window.__webbyContextMenu) return;
  const PREFIX = ${jsonEncode(prefix)};

  // Pages sometimes replace window.prompt; use a pristine one from a fresh frame if so.
  let host = window;
  const isNative = (f) => { try { return /\[native code\]/.test(Function.prototype.toString.call(f)); } catch (e) { return false; } };
  if (!isNative(window.prompt)) {
    try {
      const frame = document.createElement('iframe');
      frame.style.display = 'none';
      (document.body || document.documentElement).appendChild(frame);
      host = frame.contentWindow;
    } catch (e) {}
  }
  const prompt = host.prompt;
  const send = (message) => {
    const text = PREFIX + JSON.stringify(message);
    setTimeout(() => { try { prompt.call(host, text); } catch (e) {} }, 0);
  };

  const TEXT_INPUTS = ['', 'text', 'search', 'url', 'tel', 'email', 'password', 'number'];
  function editableOf(node) {
    for (let el = node; el; el = el.parentElement) {
      if (el instanceof HTMLTextAreaElement || el instanceof HTMLInputElement) {
        if (el.disabled || el.readOnly) return null;
        if (el instanceof HTMLInputElement && !TEXT_INPUTS.includes((el.getAttribute('type') || '').toLowerCase())) return null;
        return el;
      }
      if (el.isContentEditable) return el;
    }
    return null;
  }
  const hasSelectionApi = (el) => { try { return typeof el.selectionStart === 'number'; } catch (e) { return false; } };
  const hrefOf = (link) => typeof link.href === 'string' ? link.href : new URL(link.href.baseVal, document.baseURI).href;

  let target = null;
  let inspected = null;
  window.addEventListener('contextmenu', (event) => {
    const node = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
    // Report after the page's own handlers (to see whether one cancelled the event) and after Ladybird has selected
    // the word under the pointer.
    setTimeout(() => {
      const link = node && node.closest('a[href], area[href]');
      const image = node && node.closest('img');
      const editable = node && editableOf(node);
      const password = editable instanceof HTMLInputElement && editable.type === 'password';
      target = editable || null;
      inspected = node;
      let selection = '';
      if (password) {
        selection = '';
      } else if (editable && hasSelectionApi(editable)) {
        selection = editable.value.substring(editable.selectionStart, editable.selectionEnd);
      } else {
        selection = String(document.getSelection() || '');
      }
      send({
        type: 'contextmenu',
        prevented: event.defaultPrevented,
        link: link ? hrefOf(link) : '',
        linkText: link ? (link.textContent || '').trim().slice(0, 200) : '',
        image: image ? (image.currentSrc || image.src || '') : '',
        selection: selection.slice(0, 1 << 20),
        editable: !!editable,
        password,
      });
    }, 0);
  }, true);

  function setValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
  }
  function fireInput(el, inputType, data) {
    let event;
    try { event = new InputEvent('input', { bubbles: true, inputType, data }); } catch (e) { event = new Event('input', { bubbles: true }); }
    el.dispatchEvent(event);
  }
  // Replaces the selection in the clicked field with text ('' deletes it), the way typing would.
  function replaceSelection(el, text, inputType) {
    el.focus();
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const value = el.value;
      if (hasSelectionApi(el)) {
        const start = el.selectionStart, end = el.selectionEnd;
        setValue(el, value.slice(0, start) + text + value.slice(end));
        el.setSelectionRange(start + text.length, start + text.length);
      } else {
        setValue(el, value + text);
      }
      fireInput(el, inputType, text || null);
      return;
    }
    try {
      if (document.execCommand(text ? 'insertText' : 'delete', false, text)) return;
    } catch (e) {}
    const selection = document.getSelection();
    if (!selection || !selection.rangeCount) return;
    const range = selection.getRangeAt(0);
    range.deleteContents();
    if (text) {
      const node = document.createTextNode(text);
      range.insertNode(node);
      range.setStartAfter(node);
      range.collapse(true);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    fireInput(el, inputType, text || null);
  }

  Object.defineProperty(window, '__webbyContextMenu', {
    value: Object.freeze({
      act(action, text) {
        const el = target && target.isConnected ? target : null;
        if (action === 'cut' && el) replaceSelection(el, '', 'deleteByCut');
        else if (action === 'paste' && el && typeof text === 'string') replaceSelection(el, text, 'insertFromPaste');
        else if (action === 'inspect') {
          const eruda = window.eruda;
          if (!eruda) return;
          if (!eruda._isInit) eruda.init();
          eruda.show();
          eruda.show('elements');
          const node = inspected && inspected.isConnected ? inspected : document.body;
          try { eruda.get('elements').select(node); } catch (e) {}
        } else if (action === 'selectAll') {
          if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) { el.focus(); el.select(); }
          else if (el) { el.focus(); document.getSelection().selectAllChildren(el); }
          else document.getSelection().selectAllChildren(document.body || document.documentElement);
        }
      },
    }),
  });
})();
