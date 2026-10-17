/* Runs before the first paint, so the window opens in the right theme instead of
   flashing the light one until settings arrive from the backend. app.js caches the
   resolved theme (applyUi); with nothing cached yet, the system's light or dark. */
(function () {
  var theme = null;
  try { theme = localStorage.getItem('quire.theme'); } catch (e) { /* private mode: fall through */ }
  if (!theme) theme = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'cinema' : 'almanac';
  document.documentElement.dataset.theme = theme;
})();
