(() => {
  // Browsers give a page and its workers one IndexedDB; Ladybird keeps IndexedDB in each process's memory, and every
  // worker is a process of its own, so what a worker stores the page never sees (reams.ink syncs notes in a worker
  // and the page then reads them from IndexedDB: "not available locally yet"). The workers listed here still run as
  // real workers, off the page's thread, but their IndexedDB is a stand-in whose every call the page carries out on
  // its own IndexedDB. (Running them inside the page instead kept reams' tab busy: sync every 15 s on the page's
  // thread, and clicks such as the account card's close button waited behind it.)
  if (window.__webbyWorkerIdb) return;
  window.__webbyWorkerIdb = true;
  const bridgedWorkers = {
    'reams.ink': /\/assets\/(account-sync|search|import)-worker-[^/]*\.js$/,
  };
  // A test page can name its own workers (the page's own scripts only ever change that page).
  const pattern = bridgedWorkers[location.hostname] ?? window.__webbyBridgedWorkers;
  if (!pattern || typeof Worker !== 'function' || !window.indexedDB) return;
  const NativeWorker = Worker;
  const TAG = '__webbyIdb';

  // The worker's side, run in the worker (as source text) before the worker's own script.
  function workerSide(TAG, scriptUrl, isModule) {
    // The worker's own URL is a blob: one now, so relative URLs (reams fetches its wasm by path) resolve against
    // the script's.
    const nativeFetch = self.fetch;
    self.fetch = function fetch(input, init) {
      if (typeof input === 'string' || input instanceof URL) input = new URL(String(input), scriptUrl).href;
      return nativeFetch.call(this, input, init);
    };

    const RANGE = TAG + 'Range';
    const NativeKeyRange = self.IDBKeyRange;
    const nativeFactory = self.indexedDB;
    const post = message => self.postMessage({ [TAG]: message });
    const toError = e => new DOMException(e.message, e.name);
    const wire = v => NativeKeyRange && v instanceof NativeKeyRange
      ? { [RANGE]: true, lower: v.lower, upper: v.upper, lowerOpen: v.lowerOpen, upperOpen: v.upperOpen }
      : v;
    const names = list => {
      const a = [...list].sort();
      a.contains = name => a.includes(name);
      a.item = i => a[i] ?? null;
      return a;
    };
    let seq = 0;
    const results = new Map();   // request id -> handler for the page's answers
    const opens = new Map();     // open/delete request id -> state
    const transactions = new Map();
    const connections = new Map();

    // on<type> handlers, run as the first listener so event.target is right.
    const Target = types => class extends EventTarget {
      constructor() {
        super();
        for (const type of types) {
          this['on' + type] = null;
          this.addEventListener(type, event => {
            const handler = this['on' + type];
            if (typeof handler === 'function') handler.call(this, event);
          });
        }
      }
    };

    class VersionChangeEvent extends Event {
      constructor(type, init = {}) {
        super(type, init);
        this.oldVersion = init.oldVersion ?? 0;
        this.newVersion = init.newVersion ?? null;
      }
    }

    class Request extends Target(['success', 'error']) {
      constructor(source, transaction) {
        super();
        this.source = source ?? null;
        this.transaction = transaction ?? null;
        this.readyState = 'pending';
        this.__result = undefined;
        this.__error = null;
      }
      get result() {
        if (this.readyState !== 'done') throw new DOMException('The request has not finished.', 'InvalidStateError');
        return this.__result;
      }
      get error() {
        if (this.readyState !== 'done') throw new DOMException('The request has not finished.', 'InvalidStateError');
        return this.__error;
      }
    }

    class OpenRequest extends Request {
      constructor() {
        super();
        this.onupgradeneeded = null;
        this.onblocked = null;
        for (const type of ['upgradeneeded', 'blocked']) {
          this.addEventListener(type, event => {
            const handler = this['on' + type];
            if (typeof handler === 'function') handler.call(this, event);
          });
        }
      }
    }

    // An error event goes to the request, then (unless stopped) its transaction and database; not cancelled, it
    // aborts the transaction.
    function fail(request, error, transaction) {
      request.readyState = 'done';
      request.__result = undefined;
      request.__error = error;
      const event = new Event('error', { bubbles: true, cancelable: true });
      let stopped = false;
      const stop = event.stopPropagation, stopNow = event.stopImmediatePropagation;
      event.stopPropagation = function () { stopped = true; stop.call(this); };
      event.stopImmediatePropagation = function () { stopped = true; stopNow.call(this); };
      request.dispatchEvent(event);
      if (transaction && !stopped) transaction.dispatchEvent(event);
      if (transaction && !stopped) transaction.db.dispatchEvent(event);
      return !event.defaultPrevented;
    }

    function succeed(request, result) {
      request.readyState = 'done';
      request.__error = null;
      request.__result = result;
      request.dispatchEvent(new Event('success'));
    }

    class Transaction extends Target(['complete', 'error', 'abort']) {
      constructor(db, stores, mode, durability, id) {
        super();
        this.db = db;
        this.mode = mode;
        this.durability = durability ?? 'default';
        this.error = null;
        this.__stores = stores;
        this.__id = id;
        this.__state = 'active';
        this.__pending = 0;
        this.__objectStores = new Map();
        this.__ops = null;   // the versionchange transaction's recorded changes
      }
      get objectStoreNames() { return this.mode === 'versionchange' ? this.db.objectStoreNames : names(this.__stores); }
      objectStore(name) {
        if (this.__state === 'finished') throw new DOMException('The transaction has finished.', 'InvalidStateError');
        if (!this.objectStoreNames.contains(name)) throw new DOMException(`No objectStore named ${name} in this transaction`, 'NotFoundError');
        let store = this.__objectStores.get(name);
        if (!store) {
          store = new ObjectStore(this, name);
          this.__objectStores.set(name, store);
        }
        return store;
      }
      abort() {
        if (this.__state === 'finished') throw new DOMException('The transaction has finished.', 'InvalidStateError');
        if (this.__ops) {
          this.__aborted = true;
          this.__state = 'finished';
          return;
        }
        this.__state = 'committing';
        post({ t: 'abort', tx: this.__id });
      }
      commit() {
        if (this.__state !== 'active') throw new DOMException('The transaction is not active.', 'InvalidStateError');
        this.__commit();
      }
      __commit() {
        this.__state = 'committing';
        if (!this.__ops) post({ t: 'commit', tx: this.__id });
      }
      // Real transactions commit once nothing is pending at the end of a task; this one asks the page to then.
      __schedule() {
        if (this.__ops || this.__checking) return;
        this.__checking = true;
        setTimeout(() => {
          this.__checking = false;
          if (this.__state === 'active' && this.__pending === 0) this.__commit();
        }, 0);
      }
      __request(source, target, method, args, request = new Request(source, this)) {
        if (this.__state !== 'active') throw new DOMException('The transaction is not active.', 'TransactionInactiveError');
        if (this.__ops) {
          // Changes made while upgrading are replayed by the page in its own upgrade.
          this.__ops.push({ op: 'request', target, method, args: args.map(wire) });
          setTimeout(() => succeed(request, undefined), 0);
          return request;
        }
        const id = ++seq;
        request.__id = id;
        this.__pending++;
        const handler = message => this.__settle(request, message);
        handler.transaction = this;
        handler.request = request;
        results.set(id, handler);
        post({ t: 'req', tx: this.__id, id, target, method, args: args.map(wire) });
        return request;
      }
      __settle(request, message) {
        this.__pending--;
        if (message.error) {
          results.delete(request.__id);
          if (fail(request, toError(message.error), this) && this.__state === 'active') {
            this.error = request.__error;
            this.abort();
          }
        } else if ('cursor' in message) {
          if (!message.cursor) {
            results.delete(request.__id);
            succeed(request, null);
          } else {
            const cursor = request.__cursor ??= new (message.cursor.withValue ? CursorWithValue : Cursor)(request);
            cursor.__key = message.cursor.key;
            cursor.__primaryKey = message.cursor.primaryKey;
            cursor.__value = message.cursor.value;
            cursor.__stepped = false;
            succeed(request, cursor);
          }
        } else {
          results.delete(request.__id);
          succeed(request, message.result);
        }
        this.__schedule();
      }
      __finish(message) {
        this.__state = 'finished';
        transactions.delete(this.__id);
        const unanswered = [];
        for (const [id, handler] of [...results]) {
          if (handler.transaction !== this) continue;
          results.delete(id);
          unanswered.push(handler.request);
        }
        if (message.t === 'complete') {
          this.dispatchEvent(new Event('complete'));
        } else {
          this.error ??= message.error ? toError(message.error) : new DOMException('The transaction was aborted.', 'AbortError');
          for (const request of unanswered) fail(request, new DOMException('The transaction was aborted.', 'AbortError'), this);
          this.dispatchEvent(new Event('abort', { bubbles: true }));
        }
      }
    }

    const writes = new Set(['put', 'add', 'delete', 'clear', 'update']);

    class Source {
      __request(method, args) {
        const transaction = this.__transaction;
        if (writes.has(method) && transaction.mode === 'readonly') throw new DOMException('The transaction is read-only.', 'ReadOnlyError');
        return transaction.__request(this, this.__target, method, args);
      }
      get(query) { return this.__request('get', [query]); }
      getKey(query) { return this.__request('getKey', [query]); }
      getAll(query, count) { return this.__request('getAll', count === undefined ? [query] : [query, count]); }
      getAllKeys(query, count) { return this.__request('getAllKeys', count === undefined ? [query] : [query, count]); }
      count(query) { return this.__request('count', query === undefined ? [] : [query]); }
      openCursor(query, direction) { return this.__cursor('openCursor', query, direction); }
      openKeyCursor(query, direction) { return this.__cursor('openKeyCursor', query, direction); }
      __cursor(method, query, direction = 'next') {
        const request = this.__request(method, [query, direction]);
        request.__direction = direction;
        return request;
      }
    }

    class ObjectStore extends Source {
      constructor(transaction, name) {
        super();
        this.transaction = transaction;
        this.__transaction = transaction;
        this.__name = name;
        this.__target = { store: name };
      }
      get __meta() { return this.transaction.db.__schema.stores[this.__name]; }
      get name() { return this.__name; }
      get keyPath() { return this.__meta.keyPath; }
      get autoIncrement() { return this.__meta.autoIncrement; }
      get indexNames() { return names(Object.keys(this.__meta.indexes)); }
      put(value, key) { return this.__request('put', key === undefined ? [value] : [value, key]); }
      add(value, key) { return this.__request('add', key === undefined ? [value] : [value, key]); }
      delete(query) { return this.__request('delete', [query]); }
      clear() { return this.__request('clear', []); }
      index(name) {
        if (!(name in this.__meta.indexes)) throw new DOMException(`No index named ${name}`, 'NotFoundError');
        return new Index(this, name);
      }
      createIndex(name, keyPath, options = {}) {
        const ops = this.transaction.__ops;
        if (!ops) throw new DOMException('Indexes are created while upgrading.', 'InvalidStateError');
        if (name in this.__meta.indexes) throw new DOMException(`Index ${name} already exists`, 'ConstraintError');
        ops.push({ op: 'createIndex', store: this.__name, name, keyPath, options: { unique: !!options.unique, multiEntry: !!options.multiEntry } });
        this.__meta.indexes[name] = { keyPath, unique: !!options.unique, multiEntry: !!options.multiEntry };
        return new Index(this, name);
      }
      deleteIndex(name) {
        const ops = this.transaction.__ops;
        if (!ops) throw new DOMException('Indexes are deleted while upgrading.', 'InvalidStateError');
        if (!(name in this.__meta.indexes)) throw new DOMException(`No index named ${name}`, 'NotFoundError');
        ops.push({ op: 'deleteIndex', store: this.__name, name });
        delete this.__meta.indexes[name];
      }
    }

    class Index extends Source {
      constructor(store, name) {
        super();
        this.objectStore = store;
        this.__transaction = store.transaction;
        this.__name = name;
        this.__target = { store: store.name, index: name };
      }
      get __meta() { return this.objectStore.__meta.indexes[this.__name]; }
      get name() { return this.__name; }
      get keyPath() { return this.__meta.keyPath; }
      get unique() { return this.__meta.unique; }
      get multiEntry() { return this.__meta.multiEntry; }
    }

    class Cursor {
      constructor(request) {
        this.request = request;
        this.source = request.source;
        this.direction = request.__direction ?? 'next';
        this.__stepped = false;
      }
      get key() { return this.__key; }
      get primaryKey() { return this.__primaryKey; }
      __step(op, args) {
        const transaction = this.request.transaction;
        if (transaction.__state !== 'active') throw new DOMException('The transaction is not active.', 'TransactionInactiveError');
        if (this.__stepped) throw new DOMException('The cursor is already moving.', 'InvalidStateError');
        this.__stepped = true;
        this.request.readyState = 'pending';
        transaction.__pending++;
        post({ t: 'cursor', tx: transaction.__id, id: this.request.__id, op, args: args.map(wire) });
      }
      continue(key) { this.__step('continue', key === undefined ? [] : [key]); }
      advance(count) { this.__step('advance', [count]); }
      continuePrimaryKey(key, primaryKey) { this.__step('continuePrimaryKey', [key, primaryKey]); }
      update(value) {
        if (this.request.transaction.mode === 'readonly') throw new DOMException('The transaction is read-only.', 'ReadOnlyError');
        return this.request.transaction.__request(this, { cursor: this.request.__id }, 'update', [value]);
      }
      delete() {
        if (this.request.transaction.mode === 'readonly') throw new DOMException('The transaction is read-only.', 'ReadOnlyError');
        return this.request.transaction.__request(this, { cursor: this.request.__id }, 'delete', []);
      }
    }
    class CursorWithValue extends Cursor {
      get value() { return this.__value; }
    }

    class Database extends Target(['abort', 'close', 'error', 'versionchange']) {
      constructor(name, schema) {
        super();
        this.name = name;
        this.__schema = schema;
        this.__conn = 0;
        this.__closed = false;
        this.__upgrade = null;
      }
      get version() { return this.__schema.version; }
      get objectStoreNames() { return names(Object.keys(this.__schema.stores)); }
      transaction(storeNames, mode = 'readonly', options = {}) {
        if (this.__closed) throw new DOMException('The database connection is closing.', 'InvalidStateError');
        if (this.__upgrade) throw new DOMException('A version change transaction is running.', 'InvalidStateError');
        const stores = typeof storeNames === 'string' ? [storeNames] : [...storeNames];
        if (!stores.length) throw new DOMException('No object stores were named.', 'InvalidAccessError');
        for (const name of stores) {
          if (!(name in this.__schema.stores)) throw new DOMException(`No objectStore named ${name} in this database`, 'NotFoundError');
        }
        if (mode !== 'readonly' && mode !== 'readwrite') throw new TypeError(`Invalid transaction mode: ${mode}`);
        const id = ++seq;
        const transaction = new Transaction(this, [...new Set(stores)], mode, options?.durability, id);
        transactions.set(id, transaction);
        post({ t: 'begin', tx: id, conn: this.__conn, stores: transaction.__stores, mode, options: options?.durability ? { durability: options.durability } : undefined });
        transaction.__schedule();
        return transaction;
      }
      close() {
        if (this.__closed) return;
        this.__closed = true;
        if (this.__conn) post({ t: 'close', conn: this.__conn });
      }
      createObjectStore(name, options = {}) {
        const transaction = this.__upgrade;
        if (!transaction) throw new DOMException('Object stores are created while upgrading.', 'InvalidStateError');
        if (name in this.__schema.stores) throw new DOMException(`Object store ${name} already exists`, 'ConstraintError');
        transaction.__ops.push({ op: 'createObjectStore', name, options: { keyPath: options.keyPath ?? null, autoIncrement: !!options.autoIncrement } });
        this.__schema.stores[name] = { keyPath: options.keyPath ?? null, autoIncrement: !!options.autoIncrement, indexes: {} };
        return transaction.objectStore(name);
      }
      deleteObjectStore(name) {
        const transaction = this.__upgrade;
        if (!transaction) throw new DOMException('Object stores are deleted while upgrading.', 'InvalidStateError');
        if (!(name in this.__schema.stores)) throw new DOMException(`No objectStore named ${name}`, 'NotFoundError');
        transaction.__ops.push({ op: 'deleteObjectStore', name });
        delete this.__schema.stores[name];
        transaction.__objectStores.delete(name);
      }
    }

    class Factory {
      open(name, version) {
        if (version !== undefined && !(Number.isInteger(version) && version >= 1)) throw new TypeError('The version must be a positive integer.');
        const request = new OpenRequest();
        const id = ++seq;
        opens.set(id, { request, name: String(name), version });
        post({ t: 'open', id, name: String(name), version });
        return request;
      }
      deleteDatabase(name) {
        const request = new OpenRequest();
        const id = ++seq;
        opens.set(id, { request, deleting: true });
        post({ t: 'delete', id, name: String(name) });
        return request;
      }
      databases() {
        return new Promise((resolve, reject) => {
          const id = ++seq;
          results.set(id, message => {
            results.delete(id);
            if (message.error) reject(toError(message.error));
            else resolve(message.result);
          });
          post({ t: 'databases', id });
        });
      }
      cmp(a, b) { return nativeFactory.cmp(a, b); }
    }

    function handle(message) {
      switch (message.t) {
        case 'result': {
          results.get(message.id)?.(message);
          break;
        }
        case 'complete':
        case 'abort': {
          transactions.get(message.tx)?.__finish(message);
          break;
        }
        case 'upgrade': {
          const open = opens.get(message.id);
          if (!open) break;
          const db = new Database(open.name, message.schema);
          db.__schema.version = message.newVersion;
          const transaction = new Transaction(db, [], 'versionchange', 'default', 0);
          transaction.__ops = [];
          db.__upgrade = transaction;
          open.db = db;
          open.request.transaction = transaction;
          open.request.readyState = 'done';
          open.request.__result = db;
          open.request.dispatchEvent(new VersionChangeEvent('upgradeneeded', { oldVersion: message.oldVersion, newVersion: message.newVersion }));
          // The upgrade's changes (made in that handler and its promise callbacks) go to the page in one go.
          setTimeout(() => {
            if (transaction.__aborted) {
              opens.delete(message.id);
              db.__upgrade = null;
              transaction.error = new DOMException('The upgrade was aborted.', 'AbortError');
              transaction.dispatchEvent(new Event('abort'));
              open.request.transaction = null;
              fail(open.request, transaction.error);
              return;
            }
            post({ t: 'open', id: message.id, name: open.name, version: message.newVersion, ops: transaction.__ops });
          }, 0);
          break;
        }
        case 'opened': {
          const open = opens.get(message.id);
          if (!open) break;
          opens.delete(message.id);
          const db = open.db ?? new Database(open.name, message.schema);
          db.__schema = message.schema;
          db.__conn = message.conn;
          connections.set(message.conn, db);
          const upgrade = db.__upgrade;
          if (upgrade) {
            db.__upgrade = null;
            upgrade.__state = 'finished';
            upgrade.dispatchEvent(new Event('complete'));
            open.request.transaction = null;
          }
          succeed(open.request, db);
          break;
        }
        case 'error': {
          const open = opens.get(message.id);
          if (!open) break;
          opens.delete(message.id);
          const upgrade = open.db?.__upgrade;
          if (upgrade) {
            open.db.__upgrade = null;
            upgrade.__state = 'finished';
            upgrade.error = toError(message.error);
            upgrade.dispatchEvent(new Event('abort'));
            open.request.transaction = null;
          }
          fail(open.request, toError(message.error));
          break;
        }
        case 'blocked': {
          opens.get(message.id)?.request.dispatchEvent(new VersionChangeEvent('blocked', { oldVersion: message.oldVersion, newVersion: message.newVersion }));
          break;
        }
        case 'deleted': {
          const open = opens.get(message.id);
          if (!open) break;
          opens.delete(message.id);
          open.request.readyState = 'done';
          open.request.__result = undefined;
          open.request.dispatchEvent(new VersionChangeEvent('success', { oldVersion: message.oldVersion, newVersion: null }));
          break;
        }
        case 'versionchange': {
          connections.get(message.conn)?.dispatchEvent(new VersionChangeEvent('versionchange', { oldVersion: message.oldVersion, newVersion: message.newVersion }));
          break;
        }
        case 'closed': {
          const db = connections.get(message.conn);
          if (db) {
            db.__closed = true;
            db.dispatchEvent(new Event('close'));
          }
          break;
        }
      }
    }

    const globals = {
      indexedDB: new Factory(), IDBFactory: Factory, IDBDatabase: Database, IDBTransaction: Transaction,
      IDBObjectStore: ObjectStore, IDBIndex: Index, IDBRequest: Request, IDBOpenDBRequest: OpenRequest,
      IDBCursor: Cursor, IDBCursorWithValue: CursorWithValue, IDBVersionChangeEvent: VersionChangeEvent,
    };
    for (const [name, value] of Object.entries(globals)) {
      Object.defineProperty(self, name, { value, writable: true, configurable: true, enumerable: false });
    }

    // The page's answers never reach the worker's own handlers; the page's messages wait until its script has run
    // (a module with top-level await sets onmessage only after it), as they would for the script itself.
    let ready = !isModule;
    const early = [];
    self.addEventListener('message', event => {
      const message = event.data && event.data[TAG];
      if (message) {
        event.stopImmediatePropagation();
        handle(message);
      } else if (!ready) {
        event.stopImmediatePropagation();
        early.push(event);
      }
    });
    if (isModule) {
      import(scriptUrl).then(() => {
        ready = true;
        for (const event of early.splice(0)) {
          self.dispatchEvent(new MessageEvent('message', { data: event.data, ports: [...event.ports] }));
        }
      }, error => {
        ready = true;
        setTimeout(() => { throw error; }, 0);
      });
    } else {
      importScripts(scriptUrl);
    }
  }

  // The page's side: carries out the worker's IndexedDB calls on the page's own IndexedDB.
  const RANGE = TAG + 'Range';
  const fromWire = v => v && typeof v === 'object' && v[RANGE]
    ? (v.lower === undefined ? IDBKeyRange.upperBound(v.upper, v.upperOpen)
      : v.upper === undefined ? IDBKeyRange.lowerBound(v.lower, v.lowerOpen)
        : IDBKeyRange.bound(v.lower, v.upper, v.lowerOpen, v.upperOpen))
    : v;
  const errorOf = e => ({ name: e?.name || 'UnknownError', message: e?.message || String(e) });

  function schemaOf(db, transaction) {
    const stores = {};
    const storeNames = [...db.objectStoreNames];
    if (storeNames.length) {
      const t = transaction ?? db.transaction(storeNames, 'readonly');
      for (const name of storeNames) {
        const store = t.objectStore(name);
        const indexes = {};
        for (const indexName of [...store.indexNames]) {
          const index = store.index(indexName);
          indexes[indexName] = { keyPath: index.keyPath, unique: index.unique, multiEntry: index.multiEntry };
        }
        stores[name] = { keyPath: store.keyPath, autoIncrement: store.autoIncrement, indexes };
      }
    }
    return { version: db.version, stores };
  }

  function serve(worker) {
    const post = message => NativeWorker.prototype.postMessage.call(worker, { [TAG]: message });
    const connections = new Map();
    const transactions = new Map();
    const cursors = new Map();
    let connectionSeq = 0;

    function answer(entry, request, id, cursorKind) {
      request.onsuccess = () => {
        tick(entry);
        if (!cursorKind) {
          post({ t: 'result', id, result: request.result });
          return;
        }
        const cursor = request.result;
        if (!cursor) cursors.delete(id);
        post({
          t: 'result', id, cursor: cursor && {
            key: cursor.key, primaryKey: cursor.primaryKey,
            withValue: cursorKind === 'openCursor', value: cursorKind === 'openCursor' ? cursor.value : undefined,
          },
        });
      };
      request.onerror = event => {
        // The worker decides whether the failure aborts the transaction, as its own error handlers would.
        event.preventDefault();
        event.stopPropagation();
        tick(entry);
        post({ t: 'result', id, error: errorOf(request.error) });
      };
    }

    // A transaction takes new requests only while it's active (the task that made it, and its requests' event
    // handlers) and commits once none is pending, so the page keeps a cheap request going and places the worker's
    // requests from its handlers, until the worker says it's done.
    function tick(entry) {
      if (entry.done) return;
      for (const place of entry.queue.splice(0)) place();
      if (entry.committing) {
        entry.done = true;
        try { entry.real.commit?.(); } catch {}
        return;
      }
      if (performance.now() - entry.last > 30000) {
        entry.done = true;
        try { entry.real.abort(); } catch {}
        return;
      }
      if (entry.ticking) return;
      entry.ticking = true;
      try {
        entry.real.objectStore(entry.keep).count(-Infinity).onsuccess = () => {
          entry.ticking = false;
          tick(entry);
        };
      } catch {
        entry.ticking = false;
      }
    }

    function open(message) {
      const request = message.version === undefined ? indexedDB.open(message.name) : indexedDB.open(message.name, message.version);
      let asked = false, failure = null;
      request.onupgradeneeded = event => {
        const db = request.result, transaction = request.transaction;
        if (!message.ops) {
          // The worker runs its own upgrade handler first and sends back what it changed.
          asked = true;
          post({ t: 'upgrade', id: message.id, oldVersion: event.oldVersion, newVersion: event.newVersion, schema: schemaOf(db, transaction) });
          transaction.abort();
          return;
        }
        try {
          for (const op of message.ops) {
            if (op.op === 'createObjectStore') db.createObjectStore(op.name, op.options);
            else if (op.op === 'deleteObjectStore') db.deleteObjectStore(op.name);
            else if (op.op === 'createIndex') transaction.objectStore(op.store).createIndex(op.name, op.keyPath, op.options);
            else if (op.op === 'deleteIndex') transaction.objectStore(op.store).deleteIndex(op.name);
            else if (op.op === 'request') {
              const source = op.target.index == null ? transaction.objectStore(op.target.store) : transaction.objectStore(op.target.store).index(op.target.index);
              source[op.method](...op.args.map(fromWire)).onerror = e => e.preventDefault();
            }
          }
        } catch (e) {
          failure = e;
          transaction.abort();
        }
      };
      request.onblocked = event => post({ t: 'blocked', id: message.id, oldVersion: event.oldVersion, newVersion: event.newVersion });
      request.onsuccess = () => {
        const db = request.result;
        const conn = ++connectionSeq;
        connections.set(conn, db);
        db.onversionchange = event => post({ t: 'versionchange', conn, oldVersion: event.oldVersion, newVersion: event.newVersion });
        db.onclose = () => {
          connections.delete(conn);
          post({ t: 'closed', conn });
        };
        post({ t: 'opened', id: message.id, conn, schema: schemaOf(db) });
      };
      request.onerror = event => {
        event.preventDefault();
        if (!asked) post({ t: 'error', id: message.id, error: errorOf(failure ?? request.error) });
      };
    }

    function begin(message) {
      const db = connections.get(message.conn);
      let real;
      try {
        if (!db) throw new DOMException('The database connection is closed.', 'InvalidStateError');
        real = db.transaction(message.stores, message.mode, message.options);
      } catch (e) {
        post({ t: 'abort', tx: message.tx, error: errorOf(e) });
        return;
      }
      const entry = { real, keep: message.stores[0], queue: [], done: false, committing: false, ticking: false, last: performance.now() };
      transactions.set(message.tx, entry);
      real.oncomplete = () => {
        entry.done = true;
        transactions.delete(message.tx);
        post({ t: 'complete', tx: message.tx });
      };
      real.onabort = () => {
        entry.done = true;
        transactions.delete(message.tx);
        post({ t: 'abort', tx: message.tx, error: errorOf(real.error ?? new DOMException('The transaction was aborted.', 'AbortError')) });
      };
      real.onerror = event => event.preventDefault();
      tick(entry);
    }

    function request(message) {
      const entry = transactions.get(message.tx);
      if (!entry || entry.done) {
        post({ t: 'result', id: message.id, error: errorOf(new DOMException('The transaction is not active.', 'TransactionInactiveError')) });
        return;
      }
      entry.last = performance.now();
      entry.queue.push(() => place(entry, message));
    }

    function place(entry, message) {
      try {
        const target = message.target;
        let source;
        if (target.cursor != null) source = cursors.get(target.cursor).result;
        else {
          source = entry.real.objectStore(target.store);
          if (target.index != null) source = source.index(target.index);
        }
        const args = writes.has(message.method) ? message.args : message.args.map(fromWire);
        const real = source[message.method](...args);
        const cursorKind = message.method === 'openCursor' || message.method === 'openKeyCursor' ? message.method : null;
        if (cursorKind) cursors.set(message.id, real);
        answer(entry, real, message.id, cursorKind);
      } catch (e) {
        post({ t: 'result', id: message.id, error: errorOf(e) });
      }
    }
    const writes = new Set(['put', 'add', 'update']);

    function cursorStep(message) {
      const entry = transactions.get(message.tx);
      const step = () => {
        try {
          cursors.get(message.id).result[message.op](...message.args.map(fromWire));
        } catch (e) {
          cursors.delete(message.id);
          post({ t: 'result', id: message.id, error: errorOf(e) });
        }
      };
      if (!entry || entry.done) {
        post({ t: 'result', id: message.id, error: errorOf(new DOMException('The transaction is not active.', 'TransactionInactiveError')) });
        return;
      }
      entry.last = performance.now();
      entry.queue.push(step);
    }

    function finish(message, how) {
      const entry = transactions.get(message.tx);
      if (!entry || entry.done) return;
      if (how === 'commit') {
        // After the requests still queued; the next handler commits.
        entry.committing = true;
        return;
      }
      entry.done = true;
      try { entry.real.abort(); } catch {}
    }

    function handle(message) {
      switch (message.t) {
        case 'open': open(message); break;
        case 'close': connections.get(message.conn)?.close(); connections.delete(message.conn); break;
        case 'begin': begin(message); break;
        case 'req': request(message); break;
        case 'cursor': cursorStep(message); break;
        case 'commit': finish(message, 'commit'); break;
        case 'abort': finish(message, 'abort'); break;
        case 'delete': {
          const deleting = indexedDB.deleteDatabase(message.name);
          deleting.onsuccess = event => post({ t: 'deleted', id: message.id, oldVersion: event.oldVersion });
          deleting.onerror = event => {
            event.preventDefault();
            post({ t: 'error', id: message.id, error: errorOf(deleting.error) });
          };
          deleting.onblocked = event => post({ t: 'blocked', id: message.id, oldVersion: event.oldVersion, newVersion: null });
          break;
        }
        case 'databases': {
          Promise.resolve(indexedDB.databases ? indexedDB.databases() : []).then(
            result => post({ t: 'result', id: message.id, result }),
            e => post({ t: 'result', id: message.id, error: errorOf(e) }));
          break;
        }
      }
    }

    worker.addEventListener('message', event => {
      const message = event.data && event.data[TAG];
      if (!message) return;
      event.stopImmediatePropagation();
      handle(message);
    });
    // Terminating the worker ends what it had open here.
    Object.defineProperty(worker, 'terminate', {
      value: function terminate() {
        for (const entry of transactions.values()) {
          entry.done = true;
          try { entry.real.abort(); } catch {}
        }
        transactions.clear();
        for (const db of connections.values()) db.close();
        connections.clear();
        return NativeWorker.prototype.terminate.call(this);
      },
      writable: true, configurable: true,
    });
  }

  window.Worker = function Worker(url, options) {
    if (!new.target) throw new TypeError("Constructor Worker requires 'new'");
    let href = '';
    try { href = new URL(String(url), document.baseURI).href; } catch {}
    if (!href.startsWith(location.origin + '/') || !pattern.test(new URL(href).pathname)) return new NativeWorker(url, options);
    const isModule = options?.type === 'module';
    const source = `(${workerSide})(${JSON.stringify(TAG)}, ${JSON.stringify(href)}, ${isModule});\n`;
    const blob = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    const worker = new NativeWorker(blob, options);
    setTimeout(() => URL.revokeObjectURL(blob), 60000);
    serve(worker);
    return worker;
  };
  window.Worker.prototype = NativeWorker.prototype;
})();
