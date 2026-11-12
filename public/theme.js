// Runs before first paint (blocking, external so it works under a strict Content-Security-Policy).
// Applies the remembered appearance so there is no light/dark flash. Preferences are bounded.
(function () {
  var allowed = {
    'tt-theme': ['system', 'light', 'dark'], 'tt-accent': ['ink', 'ember', 'moss', 'plum'],
    'tt-text': ['normal', 'small', 'large'], 'tt-density': ['cozy', 'compact'], 'tt-motion': ['auto', 'reduced']
  };
  var root = document.documentElement;
  function read(key) {
    var value = null;
    try { value = localStorage.getItem(key); } catch (e) { /* private mode: defaults */ }
    return allowed[key].indexOf(value) >= 0 ? value : allowed[key][0];
  }
  function apply() {
    var theme = read('tt-theme');
    var dark = theme === 'dark' || (theme === 'system' && window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches);
    root.dataset.theme = dark ? 'dark' : 'light';
    root.dataset.themeChoice = theme;
    root.dataset.accent = read('tt-accent');
    root.dataset.text = read('tt-text');
    root.dataset.density = read('tt-density');
    root.dataset.motion = read('tt-motion');
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', dark ? '#12161f' : '#efe6d2');
  }
  apply();
  if (window.matchMedia) {
    var query = matchMedia('(prefers-color-scheme: dark)');
    if (query.addEventListener) query.addEventListener('change', apply);
  }
  window.ttAppearance = {
    options: allowed, get: read, apply: apply,
    set: function (key, value) {
      if (!allowed[key] || allowed[key].indexOf(value) < 0) return;
      try { localStorage.setItem(key, value); } catch (e) { /* still applies for this visit */ }
      apply();
    }
  };
})();
