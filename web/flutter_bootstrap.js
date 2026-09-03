{{flutter_js}}
{{flutter_build_config}}

function startEngine() {
  // Updates the index.html splash through the load stages. no
  // serviceWorkerSettings: the generated service worker is a deprecated
  // stub, and the precaching worker it cleans up after was never shipped by
  // this app.
  _flutter.loader.load({
    config: {
      // The loader defaults to fetching the renderer (skwasm.js / skwasm.wasm)
      // from gstatic.com because the build config carries an engine revision.
      // The build already copies this exact revision into canvaskit/, so load
      // it from here instead. Consumed by the loader itself, not forwarded to
      // initializeEngine.
      canvasKitBaseUrl: 'canvaskit',
    },
    onEntrypointLoaded: async function (engineInitializer) {
      const status = document.getElementById('status');
      if (status) status.textContent = 'Initializing engine…';
      // Supplying onEntrypointLoaded means the config passed to load() is
      // not forwarded to the engine; pass it to initializeEngine() if one
      // is added.
      const appRunner = await engineInitializer.initializeEngine();
      if (status) status.textContent = 'Starting…';
      await appRunner.runApp();
    },
  });
}

// Removes the splash when the engine reports its first frame.
window.addEventListener(
  'flutter-first-frame',
  () => document.getElementById('splash')?.remove(),
  { once: true },
);

// Primary-tab gate. Exactly one browser tab runs the app; the gate lives at
// page level because that is what outlives everything else: the lock is
// held by this script, so hot restarts (which tear down and rebuild the
// engine) neither need nor can release it, and the gate overlay renders
// before the engine exists. The lock is held by returning a promise that
// never settles from the granting request's callback; the browser binds it
// to the tab and auto-releases on close or crash, so a dead holder can
// never lock the app out — no heartbeats, no steal, no queue state to
// clean up.
const holdForever = () => new Promise(() => {});

// Fail loud: a broken lock request means the cross-tab guard state is
// unknown, and booting unprotected risks two tabs mutating the same OPFS
// files. Gate the page with the reason instead.
function failGate(reason) {
  document.getElementById('gate-title').textContent = 'Dynamite failed to start';
  document.getElementById('gate-hint').textContent = String(reason);
  document.getElementById('gate').classList.add('show');
}

function startApp() {
  // Every browser that can run this app (OPFS sync access handles) has Web
  // Locks; a missing API is an error, not a pass-through.
  if (!navigator.locks) {
    failGate('Web Locks API is unavailable in this browser.');
    return;
  }
  // Probe without queueing: available -> boot now and hold; held by another
  // tab -> return false (nothing is held) and queue below.
  navigator.locks
    .request('dynamite_app', { mode: 'exclusive', ifAvailable: true }, (lock) => {
      if (lock === null) return false;
      startEngine();
      return holdForever();
    })
    .then((granted) => {
      // Settles only when the probe found the lock held elsewhere: the
      // granting request's callback promise never resolves.
      if (granted) return;
      document.getElementById('gate').classList.add('show');
      navigator.locks
        .request('dynamite_app', { mode: 'exclusive' }, () => {
          document.getElementById('gate').classList.remove('show');
          startEngine();
          return holdForever();
        })
        .catch(failGate);
    })
    .catch(failGate);
}

startApp();
