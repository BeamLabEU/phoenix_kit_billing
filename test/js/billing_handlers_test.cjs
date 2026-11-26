// Runs `priv/static/assets/phoenix_kit_billing.js` in a fake page and clicks
// on it. `node --test test/js/*.cjs`, also run by `mix test`
// (test/js_handlers_test.exs).
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(
  path.join(__dirname, "../../priv/static/assets/phoenix_kit_billing.js"),
  "utf8"
);

function page() {
  const listeners = [];
  const printed = [];
  const copied = [];

  const window = {
    print: () => printed.push(true),
    navigator: { clipboard: { writeText: (text) => copied.push(text) } },
  };

  const document = {
    addEventListener: (type, fn) => listeners.push({ type, fn }),
  };

  const load = () => vm.runInNewContext(SOURCE, { window, document });
  const click = (target) =>
    listeners.filter((l) => l.type === "click").forEach((l) => l.fn({ target }));

  return { window, listeners, printed, copied, load, click };
}

// An element inside a button that carries `attrs`.
function inside(attrs) {
  const button = { getAttribute: (name) => (name in attrs ? attrs[name] : null) };

  return {
    closest: (selector) => {
      const name = selector.slice(1, -1);
      return name in attrs ? button : null;
    },
  };
}

test("the bundle defines the global js_sources/0 names", () => {
  const p = page();
  p.load();
  // No hooks: the listener is delegated. (An object of the vm context, so no deepStrictEqual.)
  assert.strictEqual(typeof p.window.PhoenixKitBillingHooks, "object");
  assert.strictEqual(Object.keys(p.window.PhoenixKitBillingHooks).length, 0);
});

test("a click inside [data-pkb-print] prints, once", () => {
  const p = page();
  p.load();
  p.click(inside({ "data-pkb-print": "" }));
  assert.strictEqual(p.printed.length, 1);
  assert.strictEqual(p.copied.length, 0);
});

test("a click inside [data-pkb-copy] copies the attribute's text as it is", () => {
  const p = page();
  p.load();
  const url = "https://example.com/webhooks/billing/stripe?a='b'";
  p.click(inside({ "data-pkb-copy": url }));
  assert.deepStrictEqual(p.copied, [url]);
  assert.strictEqual(p.printed.length, 0);
});

test("a click elsewhere does nothing, and neither does a target without closest", () => {
  const p = page();
  p.load();
  p.click(inside({}));
  p.click({});
  p.click(null);
  assert.strictEqual(p.printed.length, 0);
  assert.strictEqual(p.copied.length, 0);
});

test("no clipboard (an insecure origin) is not an error", () => {
  const p = page();
  p.window.navigator = {};
  p.load();
  p.click(inside({ "data-pkb-copy": "x" }));
  assert.strictEqual(p.copied.length, 0);
});

test("loading the bundle twice installs one listener", () => {
  const p = page();
  p.load();
  p.load();
  assert.strictEqual(p.listeners.length, 1);
  p.click(inside({ "data-pkb-print": "" }));
  assert.strictEqual(p.printed.length, 1);
});
