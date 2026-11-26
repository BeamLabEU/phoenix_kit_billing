/*
 * PhoenixKitBilling's JavaScript, declared by `js_sources/0` and folded by
 * core's `:phoenix_kit_js_sources` compiler into the host's
 * `phoenix_kit_modules.js`. Hand-written, no build step: it ships as it is.
 *
 * It holds what the templates used to do with inline handlers
 * (`onclick="window.print()"`). A Content-Security-Policy without
 * 'unsafe-inline' blocks those and no nonce can be put on an attribute, so
 * the markup names what it wants and one click listener on the document does
 * it. No LiveView hook: a delegated listener needs no `phx-hook`, no id, and
 * keeps working across live navigation.
 *
 *   data-pkb-print          a click prints the page
 *   data-pkb-copy="text"    a click copies the text to the clipboard
 */
(function () {
  "use strict";

  if (typeof window === "undefined" || typeof document === "undefined") return;

  // The global `js_sources/0` names. This bundle has no hooks, but the
  // compiler folds `window.PhoenixKitBillingHooks` into `PhoenixKitHooks`.
  window.PhoenixKitBillingHooks = window.PhoenixKitBillingHooks || {};

  // A host may load the bundle twice (the modules file and an import of its
  // own): one listener, or a click would print twice.
  if (window.__pkBillingLoaded) return;
  window.__pkBillingLoaded = true;

  function closest(target, selector) {
    return target && typeof target.closest === "function" ? target.closest(selector) : null;
  }

  document.addEventListener("click", function (event) {
    if (closest(event.target, "[data-pkb-print]")) {
      window.print();
      return;
    }

    var copy = closest(event.target, "[data-pkb-copy]");

    if (copy && window.navigator && window.navigator.clipboard) {
      window.navigator.clipboard.writeText(copy.getAttribute("data-pkb-copy"));
    }
  });
})();
