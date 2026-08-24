{{flutter_js}}
{{flutter_build_config}}

// Updates the index.html splash through the load stages and removes it when
// the engine reports its first frame. no serviceWorkerSettings: the
// generated service worker is a deprecated stub, and the precaching worker
// it cleans up after was never shipped by this app.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const status = document.getElementById('status');
    if (status) status.textContent = 'Initializing engine…';
    // Supplying onEntrypointLoaded means the config passed to load() is not
    // forwarded to the engine; pass it to initializeEngine() if one is added.
    const appRunner = await engineInitializer.initializeEngine();
    if (status) status.textContent = 'Starting…';
    await appRunner.runApp();
  },
});

window.addEventListener(
  'flutter-first-frame',
  () => document.getElementById('splash')?.remove(),
  { once: true },
);
