(() => {
  // Screen recording, which Ladybird doesn't have: navigator.mediaDevices.getDisplayMedia() and MediaRecorder.
  // webby shares the screen through the desktop's portal (or X11) with its webby-screencast helper, which encodes
  // WebM; this script makes the page's side of it (features/site/screencapture.nim). Only recording is offered: the
  // shared screen's track carries no frames for the page itself, so a <video> preview of it stays empty.
  if (window.__webbyCapture) return;
  const md = navigator.mediaDevices;
  if (!md || typeof MediaStream === 'undefined' || typeof AudioContext === 'undefined') return;
  if (typeof md.getDisplayMedia === 'function' && window.MediaRecorder && !window.MediaRecorder.__webbyStandIn) return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const send = (message) => { try { prompt.call(window, PREFIX + JSON.stringify(message)); } catch (e) {} };
  const TYPE = 'video/webm;codecs=vp8,opus';

  const self = {
    nextId: 1,
    waiting: new Map(),    // request id -> { resolve, reject, audio }
    captures: new Map(),   // capture id (= its request id) -> { tracks, ended, recorder, audio }
    micTracks: new Set(),  // the page's microphone tracks, so a recording knows to take the microphone too
    granted(id, width, height, surface) {
      const w = self.waiting.get(id);
      self.waiting.delete(id);
      if (!w) { send({ type: 'captureEnd', capture: id }); return; }
      const capture = { id, tracks: [], ended: false, recorder: null, audio: w.audio };
      const settings = { width, height, frameRate: 30, aspectRatio: height ? width / height : 0,
        displaySurface: surface, logicalSurface: true, cursor: 'always', deviceId: 'webby-screen-' + id };
      capture.tracks.push(makeTrack(capture, 'video', surface === 'window' ? 'window:' + id : 'screen:' + id, settings));
      if (w.audio) capture.tracks.push(makeTrack(capture, 'audio', 'System audio', { deviceId: 'webby-audio-' + id }));
      self.captures.set(id, capture);
      w.resolve(new MediaStream(capture.tracks));
    },
    denied(id, name, message) {
      const w = self.waiting.get(id);
      self.waiting.delete(id);
      if (w) w.reject(new DOMException(message, name));
    },
    ended(id) {
      const capture = self.captures.get(id);
      if (!capture || capture.ended) return;
      capture.ended = true;
      for (const track of capture.tracks) track.dispatchEvent(new Event('ended'));
    },
    data(id, base64) {
      const capture = self.captures.get(id);
      if (!capture || !capture.recorder) return;
      const text = atob(base64);
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
      capture.recorder._chunks.push(bytes);
    },
    error(id, message) {
      const capture = self.captures.get(id);
      if (capture && capture.recorder) capture.recorder._fail(message);
    },
    stopped(id) {
      const capture = self.captures.get(id);
      if (!capture || !capture.recorder) return;
      const recorder = capture.recorder;
      capture.recorder = null;
      recorder._finish();
    },
  };
  Object.defineProperty(window, '__webbyCapture', { value: self });

  const handlerProperty = (target, name) => {
    let handler = null;
    Object.defineProperty(target, 'on' + name, {
      get: () => handler,
      set: (value) => {
        if (handler) target.removeEventListener(name, handler);
        handler = typeof value === 'function' ? value : null;
        if (handler) target.addEventListener(name, handler);
      },
      configurable: true,
    });
  };

  // MediaStream only takes the engine's own tracks and the engine can't capture video, so each shared track is a
  // silent track from an AudioContext stream destination, dressed as the screen.
  let audioContext = null;
  function makeTrack(capture, kind, label, settings) {
    if (!audioContext) audioContext = new AudioContext();
    const track = audioContext.createMediaStreamDestination().stream.getAudioTracks()[0];
    let enabled = true, stopped = false;
    const value = (v) => ({ value: v, configurable: true, writable: true });
    Object.defineProperties(track, {
      kind: { get: () => kind, configurable: true },
      label: { get: () => label, configurable: true },
      enabled: { get: () => enabled, set: (v) => { enabled = !!v; }, configurable: true },
      muted: { get: () => false, configurable: true },
      readyState: { get: () => (stopped || capture.ended ? 'ended' : 'live'), configurable: true },
      contentHint: value(''),
      getSettings: value(() => Object.assign({}, settings)),
      getCapabilities: value(() => ({})),
      getConstraints: value(() => ({})),
      applyConstraints: value(() => Promise.resolve()),
      clone: value(() => track),
      stop: value(() => {
        if (stopped) return;
        stopped = true;
        // The screen stays shared until its last track stops.
        if (!capture.ended && capture.tracks.every((t) => t.readyState === 'ended')) {
          capture.ended = true;
          send({ type: 'captureEnd', capture: capture.id });
        }
      }),
      __webbyCapture: { value: capture },
    });
    for (const name of ['ended', 'mute', 'unmute']) handlerProperty(track, name);
    return track;
  }

  // The engine's getVideoTracks() goes by the tracks' real kind; go by the one they show.
  const getTracks = MediaStream.prototype.getTracks;
  MediaStream.prototype.getVideoTracks = function () { return getTracks.call(this).filter((t) => t.kind === 'video'); };
  MediaStream.prototype.getAudioTracks = function () { return getTracks.call(this).filter((t) => t.kind === 'audio'); };

  Object.defineProperty(md, 'getDisplayMedia', {
    value: function getDisplayMedia(options) {
      return new Promise((resolve, reject) => {
        if (options && options.video === false)
          throw new TypeError("Failed to execute 'getDisplayMedia': video must be requested");
        const id = self.nextId++;
        self.waiting.set(id, { resolve, reject, audio: !!(options && options.audio) });
        send({ type: 'captureRequest', id });
      });
    },
    configurable: true,
    writable: true,
  });

  if (typeof md.getUserMedia === 'function') {
    const getUserMedia = md.getUserMedia;
    md.getUserMedia = function (constraints) {
      return getUserMedia.apply(this, arguments).then((stream) => {
        for (const track of stream.getAudioTracks()) {
          self.micTracks.add(track);
          track.addEventListener('ended', () => self.micTracks.delete(track));
        }
        return stream;
      });
    };
  }

  const supported = (type) => {
    const m = /^\s*video\/webm\s*(?:;\s*codecs\s*=\s*"?([^"]*)"?\s*)?$/i.exec(String(type));
    if (!m) return false;
    return !m[1] || m[1].split(',').every((c) => ['vp8', 'vp8.0', 'opus'].includes(c.trim().toLowerCase()));
  };

  class BlobEvent extends Event {
    constructor(type, init) {
      super(type, init);
      this.data = init && init.data;
      this.timecode = init && init.timecode !== undefined ? init.timecode : performance.now();
    }
  }
  if (!window.BlobEvent) Object.defineProperty(window, 'BlobEvent', { value: BlobEvent, writable: true, configurable: true });

  class MediaRecorder extends EventTarget {
    constructor(stream, options = {}) {
      super();
      if (!(stream instanceof MediaStream))
        throw new TypeError("Failed to construct 'MediaRecorder': parameter 1 is not of type 'MediaStream'.");
      const type = (options && options.mimeType) || '';
      if (type && !supported(type)) throw new DOMException(`Unsupported mimeType: ${type}`, 'NotSupportedError');
      this._stream = stream;
      this._mimeType = type;
      this._state = 'inactive';
      this._chunks = [];
      this._timer = 0;
      this._capture = null;
      this.videoBitsPerSecond = 3000000;
      this.audioBitsPerSecond = 128000;
      this.audioBitrateMode = 'variable';
      for (const name of ['start', 'stop', 'dataavailable', 'pause', 'resume', 'error']) handlerProperty(this, name);
    }
    get stream() { return this._stream; }
    get mimeType() { return this._mimeType; }
    get state() { return this._state; }
    static isTypeSupported(type) { return supported(type); }

    start(timeslice) {
      if (this._state !== 'inactive') throw new DOMException('The MediaRecorder is already recording', 'InvalidStateError');
      const tracks = this._stream.getTracks();
      const screen = tracks.find((t) => t.kind === 'video' && t.__webbyCapture);
      if (!screen) throw new DOMException('Only a shared screen can be recorded in this browser', 'NotSupportedError');
      const capture = screen.__webbyCapture;
      if (capture.ended) throw new DOMException('The shared screen has ended', 'InvalidStateError');
      if (capture.recorder) throw new DOMException('The shared screen is already being recorded', 'NotSupportedError');
      const audio = tracks.some((t) => t.kind === 'audio' && t.readyState === 'live');
      const microphone = audio && [...self.micTracks].some((t) => t.readyState === 'live' && t.enabled);
      capture.recorder = this;
      this._capture = capture;
      this._state = 'recording';
      this._chunks = [];
      this._mimeType = TYPE;
      send({ type: 'captureStart', capture: capture.id, systemAudio: audio && capture.audio, microphone });
      const slice = Number(timeslice);
      if (slice > 0) this._timer = setInterval(() => this._emit(), Math.max(slice, 100));
      setTimeout(() => this.dispatchEvent(new Event('start')), 0);
    }
    requestData() {
      if (this._state === 'inactive') throw new DOMException('The MediaRecorder is not recording', 'InvalidStateError');
      setTimeout(() => this._emit(), 0);
    }
    pause() {
      if (this._state === 'inactive') throw new DOMException('The MediaRecorder is not recording', 'InvalidStateError');
      if (this._state === 'paused') return;
      this._state = 'paused';
      send({ type: 'capturePause', capture: this._capture.id });
      setTimeout(() => this.dispatchEvent(new Event('pause')), 0);
    }
    resume() {
      if (this._state === 'inactive') throw new DOMException('The MediaRecorder is not recording', 'InvalidStateError');
      if (this._state === 'recording') return;
      this._state = 'recording';
      send({ type: 'captureResume', capture: this._capture.id });
      setTimeout(() => this.dispatchEvent(new Event('resume')), 0);
    }
    stop() {
      if (this._state === 'inactive') return;
      this._state = 'inactive';
      // The helper finishes the file; 'stop' follows its last bytes (self.stopped).
      send({ type: 'captureStop', capture: this._capture.id });
    }
    _emit() {
      const data = new Blob(this._chunks, { type: this._mimeType });
      this._chunks = [];
      this.dispatchEvent(new BlobEvent('dataavailable', { data }));
    }
    _fail(message) {
      const event = new Event('error');
      event.error = new DOMException(message, 'UnknownError');
      this.dispatchEvent(event);
    }
    _finish() {
      clearInterval(this._timer);
      this._state = 'inactive';
      this._emit();
      this.dispatchEvent(new Event('stop'));
    }
  }
  Object.defineProperty(window, 'MediaRecorder', { value: MediaRecorder, writable: true, configurable: true });
})();
