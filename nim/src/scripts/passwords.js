
(() => {
  if (window.__webbyPasswords) return;
  const PREFIX = ${jsonEncode(prefix)};

  // The view takes prompt() calls that start with PREFIX as messages and answers them at once, without showing
  // anything. (console.log would also reach the browser, but WebContent copies console output to its log.) Pages
  // sometimes replace window.prompt; use a pristine one from a fresh frame if so.
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
  const send = (message) => { try { prompt.call(host, PREFIX + JSON.stringify(message)); } catch (e) {} };

  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const usable = (el) => !el.disabled && !el.readOnly && visible(el);
  // A form's controls include those outside it tied to it by a form="id" attribute, so read its elements.
  const inputsOf = (root) => root instanceof HTMLFormElement
    ? Array.from(root.elements).filter((el) => el instanceof HTMLInputElement)
    : Array.from((root || document).querySelectorAll('input'));
  const passwordFields = (root) => inputsOf(root).filter((el) => el.type === 'password' && usable(el));
  const isTextLike = (el) => el.tagName === 'INPUT' &&
    ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase());

  function usernameFieldFor(password) {
    const inputs = inputsOf(password.form).filter(usable);
    const tagged = inputs.find((el) => isTextLike(el) && /\busername\b|\bemail\b/.test(el.getAttribute('autocomplete') || ''));
    if (tagged) return tagged;
    const index = inputs.indexOf(password);
    for (let i = index - 1; i >= 0; i--) {
      if (isTextLike(inputs[i])) return inputs[i];
    }
    return inputs.find(isTextLike) || null;
  }

  // A field for choosing a password rather than entering one. Tagged new-password, or untagged and one of several
  // password fields in its form: next to a tagged one (the confirm field, or the new one beside current-password),
  // as password + confirm, or as the 2nd/3rd of current + new + confirm.
  const autocompleteOf = (el) => (el.getAttribute('autocomplete') || '').toLowerCase();
  function isNewPasswordField(el) {
    if (!(el instanceof HTMLInputElement) || el.type !== 'password') return false;
    const autocomplete = autocompleteOf(el);
    if (autocomplete === 'new-password') return true;
    if (autocomplete === 'current-password') return false;
    const fields = passwordFields(el.form);
    const untagged = fields.filter((f) => !['current-password', 'new-password'].includes(autocompleteOf(f)));
    if (untagged.length < fields.length) return true;
    if (untagged.length === 2) return true;
    return untagged.length >= 3 && untagged.indexOf(el) > 0;
  }

  let lastSent = '';
  function capture(root) {
    const filled = passwordFields(root).filter((el) => el.value);
    if (!filled.length) return;
    // Sign-up and change-password forms: the new password is the one to keep.
    const password = filled.find((el) => el.getAttribute('autocomplete') === 'new-password') || filled[filled.length - 1];
    const usernameField = usernameFieldFor(filled[0]);
    const username = usernameField ? usernameField.value.trim() : '';
    const key = username + '\u0000' + password.value;
    if (key === lastSent) return;
    lastSent = key;
    send({ type: 'submit', username, password: password.value });
  }

  document.addEventListener('submit', (event) => capture(event.target), true);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && event.target instanceof HTMLInputElement && passwordFields(event.target.form).length)
      capture(event.target.form);
  }, true);
  document.addEventListener('click', (event) => {
    const button = event.target instanceof Element && event.target.closest('button, input[type=submit], input[type=button], [role=button]');
    if (!button) return;
    const form = button.form || button.closest('form');
    if (passwordFields(form).some((el) => el.value)) capture(form);
  }, true);
  let filling = false;
  document.addEventListener('focusin', (event) => {
    const el = event.target;
    if (filling) return;
    if (!(el instanceof HTMLInputElement)) return;
    if (isNewPasswordField(el)) send({ type: 'newPassword' });
    else if (el.type === 'password' || (isTextLike(el) && passwordFields(el.form).length)) send({ type: 'focus' });
  }, true);

  // Not while the document is still being parsed: a prompt() then leaves Ladybird's parser paused for good (no
  // DOMContentLoaded, no first paint, the page loading forever; LWN's login bar did it). DOMContentLoaded checks
  // instead.
  let hadFields = false;
  function checkFields() {
    if (document.readyState === 'loading') return;
    const has = passwordFields(document).length > 0;
    if (has && !hadFields) send({ type: 'fields' });
    hadFields = has;
  }
  let pending = 0;
  new MutationObserver(() => {
    if (!pending) pending = setTimeout(() => { pending = 0; checkFields(); }, 300);
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden'] });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', checkFields, { once: true });
  else checkFields();

  function setValue(el, value) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  Object.defineProperty(window, '__webbyPasswords', {
    value: Object.freeze({
      fill(username, password, origin) {
        if (location.origin !== origin) return;
        const passwords = passwordFields(document);
        const target = passwords.find((el) => el === document.activeElement) ||
          passwords.find((el) => el.getAttribute('autocomplete') === 'current-password') || passwords[0];
        if (!target) return;
        const usernameField = usernameFieldFor(target);
        filling = true;
        try {
          if (usernameField && username) setValue(usernameField, username);
          setValue(target, password);
        } finally {
          filling = false;
        }
        lastSent = (username || '') + '\u0000' + password;
      },
      // Puts a generated password in the new-password field the user is on and in its confirm field.
      fillNew(password, origin) {
        if (location.origin !== origin) return;
        const passwords = passwordFields(document);
        const focused = passwords.find((el) => el === document.activeElement);
        const first = focused && isNewPasswordField(focused) ? focused : passwords.find(isNewPasswordField);
        if (!first) return;
        const targets = passwordFields(first.form).filter((el) => el === first || isNewPasswordField(el));
        filling = true;
        try {
          for (const el of targets) setValue(el, password);
          first.focus();
        } finally {
          filling = false;
        }
      },
    }),
  });
})();
