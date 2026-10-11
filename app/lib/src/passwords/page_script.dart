import 'dart:convert';

/// JavaScript the password manager runs in each top-level page.
///
/// It watches login forms and reports to the browser by calling prompt() with a string that starts with [prefix] (the
/// view answers those itself and queues them for Dart, see `webby_view_set_message_prefix`). Messages are JSON:
///   {"type": "fields"}   the page has a visible password field (sent once per page, and again when one appears)
///   {"type": "focus"}    the user focused a username or password field
///   {"type": "newPassword"}   the user focused a field for choosing a new password (sign-up or change password)
///   {"type": "submit", "username", "password"}   a login was sent (form submit, Enter, or a click on a button)
/// It also defines `window.__webbyPasswords.fill(username, password, origin)` and `.fillNew(password, origin)` for the
/// browser to call.
///
/// The prefix carries a random token per browser session, so frames and scripts that don't know it can't pose as this
/// script. It runs again after every load; a page that already has it keeps the first copy.
String passwordPageScript(String prefix) => '''
(() => {
  if (window.__webbyPasswords) return;
  const PREFIX = ${jsonEncode(prefix)};

  // The view takes prompt() calls that start with PREFIX as messages and answers them at once, without showing
  // anything. (console.log would also reach the browser, but WebContent copies console output to its log.) Pages
  // sometimes replace window.prompt; use a pristine one from a fresh frame if so.
  let host = window;
  const isNative = (f) => { try { return /\\[native code\\]/.test(Function.prototype.toString.call(f)); } catch (e) { return false; } };
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
  const passwordFields = (root) =>
    Array.from((root || document).querySelectorAll('input[type=password]')).filter(usable);
  const isTextLike = (el) => el.tagName === 'INPUT' &&
    ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase());

  function usernameFieldFor(password) {
    const scope = password.form || document;
    const inputs = Array.from(scope.querySelectorAll('input')).filter(usable);
    const tagged = inputs.find((el) => isTextLike(el) && /\\busername\\b|\\bemail\\b/.test(el.getAttribute('autocomplete') || ''));
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
    const key = username + '\\u0000' + password.value;
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

  let hadFields = false;
  function checkFields() {
    const has = passwordFields(document).length > 0;
    if (has && !hadFields) send({ type: 'fields' });
    hadFields = has;
  }
  let pending = 0;
  new MutationObserver(() => {
    if (!pending) pending = setTimeout(() => { pending = 0; checkFields(); }, 300);
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden'] });
  checkFields();

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
        lastSent = (username || '') + '\\u0000' + password;
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
''';

/// JavaScript that puts a generated [password] into the page's new-password fields, if the page is still on [origin].
String passwordFillNewScript(String origin, String password) =>
    'window.__webbyPasswords && window.__webbyPasswords.fillNew(${jsonEncode(password)}, ${jsonEncode(origin)});';

/// JavaScript that fills [username] and [password] into the page's login form, if the page is still on [origin].
String passwordFillScript(String origin, String username, String password) =>
    'window.__webbyPasswords && window.__webbyPasswords.fill(${jsonEncode(username)}, ${jsonEncode(password)}, '
    '${jsonEncode(origin)});';
