(() => {
  if (window.__webbyMedia) return;
  // The page's audio and video for the desktop's media controls (MPRIS, features/plasma/mpris.nim): which element
  // plays, its title, artist and artwork (from navigator.mediaSession, which Ladybird doesn't have, so it's
  // provided here), and the controls' actions coming back through window.__webbyMedia(action, value).
  const PREFIX = __WEBBY_MEDIA_PREFIX__;
  const prompt = window.prompt;
  const tracked = new Set();
  let current = null, queued = false;
  let lastSent = JSON.stringify({ type: 'media', state: 'none', position: 0 });   // nothing to say yet

  // navigator.mediaSession, as far as players use it: metadata, playbackState, action handlers, position state.
  const handlers = {};
  let metadata = null, playbackState = 'none', positionState = null;
  if (!('mediaSession' in navigator)) {
    class MediaMetadata {
      constructor(init = {}) {
        this.title = String(init.title || '');
        this.artist = String(init.artist || '');
        this.album = String(init.album || '');
        this.artwork = Array.from(init.artwork || [], a => ({ src: String(a.src || ''), sizes: String(a.sizes || ''), type: String(a.type || '') }));
      }
    }
    window.MediaMetadata = MediaMetadata;
    const session = {
      get metadata() { return metadata; },
      set metadata(m) { metadata = m || null; schedule(); },
      get playbackState() { return playbackState; },
      set playbackState(s) { if (['none', 'paused', 'playing'].includes(s)) { playbackState = s; schedule(); } },
      setActionHandler(action, handler) { if (handler) handlers[action] = handler; else delete handlers[action]; schedule(); },
      setPositionState(state) { positionState = state || null; schedule(); },
      setMicrophoneActive() {}, setCameraActive() {},
    };
    try { Object.defineProperty(Navigator.prototype, 'mediaSession', { get: () => session, configurable: true }); } catch (e) {}
  }

  const audible = m => !m.muted && m.volume > 0 && !(m.duration > 0 && m.duration < 5);
  const pick = () => {
    // The element playing (the last one to start), else the one that played last, while it's still there.
    for (const m of tracked) if (!m.isConnected && m.paused && m !== current) tracked.delete(m);
    const playing = [...tracked].filter(m => !m.paused && !m.ended && audible(m));
    if (playing.length) {
      if (!playing.includes(current)) current = playing[playing.length - 1];
    } else if (current && (!tracked.has(current) || current.ended && !current.loop || !current.currentSrc)) current = null;
    return current;
  };

  const artwork = () => {
    const art = metadata && metadata.artwork || [];
    let best = '', size = -1;
    for (const a of art) {
      const s = parseInt(String(a.sizes || '').split(/[x\s]/)[0]) || 0;
      if (a.src && s > size) { best = a.src; size = s; }
    }
    try { return best ? new URL(best, location.href).href : ''; } catch (e) { return ''; }
  };

  const report = () => {
    queued = false;
    if (document.readyState === 'loading') return;   // a prompt() while parsing can wedge Ladybird's parser
    const m = pick();
    let state = 'none';
    if (m) state = m.paused ? 'paused' : 'playing';
    else if (metadata && playbackState !== 'none') state = playbackState;
    const info = { type: 'media', state };
    if (state !== 'none') {
      const duration = m && isFinite(m.duration) ? m.duration : (positionState && positionState.duration) || 0;
      Object.assign(info, {
        title: metadata && metadata.title || document.title || location.hostname,
        artist: metadata && metadata.artist || '', album: metadata && metadata.album || '', art: artwork(),
        duration, position: m ? m.currentTime : (positionState && positionState.position) || 0,
        rate: m ? m.playbackRate : 1, volume: m ? (m.muted ? 0 : m.volume) : 1,
        canNext: !!handlers.nexttrack, canPrevious: !!handlers.previoustrack,
        canSeek: !!(m && duration > 0 && m.seekable && m.seekable.length) || !!handlers.seekto,
      });
    }
    const text = JSON.stringify(info);
    // Positions move all the time; send them only with another change (or a seek, which sends 'seeked').
    const key = JSON.stringify(Object.assign({}, info, { position: 0 }));
    if (key === lastSent && !report.force) return;
    report.force = false;
    lastSent = key;
    setTimeout(() => { try { prompt.call(window, PREFIX + text); } catch (e) {} }, 0);
  };
  const schedule = (force) => {
    if (force) report.force = true;
    if (queued) return;
    queued = true;
    setTimeout(report, 50);
  };

  const track = m => { if (m instanceof HTMLMediaElement && !tracked.has(m)) tracked.add(m); };
  const events = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'durationchange', 'volumechange'];
  for (const e of events) document.addEventListener(e, ev => { track(ev.target); schedule(); }, true);
  for (const e of ['seeked', 'ratechange']) document.addEventListener(e, ev => { track(ev.target); schedule(true); }, true);
  // An Audio() that never joins the document only shows itself through play().
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    if (!tracked.has(this)) {
      tracked.add(this);
      for (const e of events) this.addEventListener(e, () => schedule());
      for (const e of ['seeked', 'ratechange']) this.addEventListener(e, () => schedule(true));
    }
    return play.apply(this, args);
  };
  for (const m of document.querySelectorAll('audio, video')) track(m);

  const run = (name, details) => {
    const h = handlers[name];
    if (!h) return false;
    try { h(Object.assign({ action: name }, details)); } catch (e) {}
    return true;
  };
  window.__webbyMedia = (action, value) => {
    const m = pick();
    switch (action) {
      case 'play': if (!run('play') && m) m.play().catch(() => {}); break;
      case 'pause': if (!run('pause') && m) m.pause(); break;
      case 'playpause':
        if (m ? m.paused : playbackState !== 'playing') window.__webbyMedia('play'); else window.__webbyMedia('pause');
        break;
      case 'stop': if (!run('stop') && m) m.pause(); break;
      case 'next': run('nexttrack'); break;
      case 'previous': run('previoustrack'); break;
      case 'seek':   // value: seconds from the current position
        if (!run('seekto', { seekTime: Math.max(0, (m ? m.currentTime : 0) + value) }) && m) m.currentTime = Math.max(0, m.currentTime + value);
        break;
      case 'position':   // value: seconds from the start
        if (!run('seekto', { seekTime: value }) && m) m.currentTime = value;
        break;
      case 'volume': if (m) { m.muted = value <= 0; if (value > 0) m.volume = Math.min(1, value); } break;
    }
    schedule(true);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => schedule(), { once: true });
  else if (tracked.size) schedule();
})();
