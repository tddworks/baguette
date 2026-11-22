'use strict';

// The focus-mode template's <style> blocks carry the whole layout, and a
// CSS parse error in them is silent: the browser skips to the next thing
// it recognises, taking whatever rules were in between with it. That is
// not theoretical — an unterminated comment twice swallowed the block
// defining `--nv-device-max-*`, and the only symptom was the device
// rendering at its natural size with no cap, which looks like a sizing
// bug rather than a syntax one.
//
// So: two checks over the file's own text. Nothing here understands CSS
// — they catch the shapes that actually broke it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const TEMPLATE = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'page/device-page.html'
);

/** The concatenated contents of every `<style>` block in an HTML file. */
function styleBlocks(html) {
  return [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)]
    .map((m) => m[1]).join('\n');
}

/**
 * Comment delimiters, in order, with the line each sits on. A `*​/` with
 * no open comment before it means the prose above it is being fed to the
 * CSS parser as if it were a rule.
 */
function unbalancedCommentLine(css) {
  const lines = css.split('\n');
  let open = false;
  for (let i = 0; i < lines.length; i++) {
    for (const token of lines[i].match(/\/\*|\*\//g) || []) {
      if (token === '/*') {
        if (open) return i + 1;   // nested open — CSS comments don't nest
        open = true;
      } else {
        if (!open) return i + 1;  // close with nothing open
        open = false;
      }
    }
  }
  return open ? lines.length : 0;
}

/**
 * Custom properties, split by whether the stylesheet can stand on its own
 * for them.
 *
 * `used` counts only `--nv-*` read WITHOUT a fallback, which is the shape
 * that fails loudly in layout and silently in the console. A `var(--x,
 * something)` is a deliberate optional hook, and a non-`--nv-` name may
 * be set inline from JS (`page/internal/device-3d.js` writes `--swatch` on each element) —
 * neither can be judged from this file alone.
 */
function customProperties(css) {
  const used = new Set(
    [...css.matchAll(/var\(\s*(--nv-[\w-]+)\s*\)/g)].map((m) => m[1])
  );
  const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1]));
  return { used, defined };
}

test('should close every CSS comment in the device page\'s template', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.equal(
    unbalancedCommentLine(css), 0,
    'unbalanced /* */ — everything from here to the next recognisable ' +
    'rule is being parsed as CSS and silently dropped'
  );
});

test('should find a CSS comment closed twice', () => {
  // The exact shape that broke it: prose left outside the comment after
  // an early `*/`, with a stray `*/` of its own at the end.
  const broken = [
    '/* explanation',
    '   more explanation */',
    '   prose that is no longer inside the comment */',
    '#root { --x: 1px; }',
  ].join('\n');
  assert.equal(unbalancedCommentLine(broken), 3);
});

test('should find a CSS comment never closed', () => {
  assert.equal(unbalancedCommentLine('/* opened\nand never closed\n'), 3);
});

test('should define every --nv-* token the stylesheet reads without a fallback', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  const { used, defined } = customProperties(css);
  const missing = [...used].filter((name) => !defined.has(name));
  assert.deepEqual(
    missing, [],
    'var() with no definition resolves to nothing and the whole ' +
    'declaration is dropped — the usual cause is a rule block lost to a ' +
    'parse error above it'
  );
});

test('should define in the size budget every variable the device and panes size from', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  const { defined } = customProperties(css);
  for (const name of [
    '--nv-vh',
    '--nv-device-max-w', '--nv-device-max-h',
    '--nv-companion-max-w', '--nv-companion-max-h',
  ]) {
    assert.ok(defined.has(name), `${name} is not defined anywhere`);
  }
});

// The two checks below are about *where* focus-mode styling lives, not
// whether it parses. A panel that ships its own stylesheet is styling
// itself against a token set it can't see, so it drifts — different
// radii, a shadow that never learned about dark mode, an accent pulled
// from whatever `--accent` happens to mean on the page it landed on.
// The rest of the focus chrome (logs, status bar, location, the a11y
// inspector) contributes zero CSS and is styled here; these keep it that
// way.

/** Panel modules that render into `#simNativeView` and must not carry CSS. */
const PANEL_MODULES = ['page/internal/plugins/plugins-rail.js', 'families/simulator/internal/screens-rail.js'];

test('should leave styling to the template when a panel module renders into the view', () => {
  for (const name of PANEL_MODULES) {
    const src = fs.readFileSync(path.join(path.dirname(TEMPLATE), '..', name), 'utf8');
    assert.ok(
      !/createElement\(\s*['"]style['"]\s*\)/.test(src),
      `${name} builds a <style> element — focus-mode CSS belongs in ` +
      'page/device-page.html under #simNativeView, where the --nv-* tokens are'
    );
  }
});

test('should read no token from outside the --nv-* set in the focus-mode stylesheet', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  // `--bg` / `--text` are the standalone-preview :root in <head>, which
  // only applies under file://; `--swatch` is written per-element from
  // page/internal/device-3d.js. Everything else must come from the theme block, because
  // only those names are redefined for light and dark.
  const allowed = new Set(['--bg', '--text', '--swatch']);
  const foreign = [...new Set(
    [...css.matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1])
  )].filter((name) => !name.startsWith('--nv-') && !allowed.has(name));
  assert.deepEqual(
    foreign, [],
    'these resolve against sim.html\'s light-only :root, so they never ' +
    'change for dark mode — use the --nv-* equivalent'
  );
});

// ── Capture surface ──────────────────────────────────────────────
// Focus mode is the screen people actually capture from, so the
// output-size picker and the Record button have to be reachable there.
// Both are wired the way every other control in this toolbar is —
// markup in page/device-page.html, a `window.__nativeXxx` indirection in
// page/device-page.js — and both are easy to half-land (a button with no
// handler, a handler with no button). These pin the pairing.

const WEB_ROOT = path.join(path.dirname(TEMPLATE), '..');
const SCRIPT = path.join(WEB_ROOT, 'page', 'device-page.js');

/** The `#simNativeView` markup, with the `<style>` blocks taken out. */
function markup(html) {
  return html.replace(/<style[^>]*>[\s\S]*?<\/style>/g, '');
}

test('should mount the capture-size picker in the toolbar', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.match(
    html, /id="nativeCaptureSize"/,
    'CaptureSizeMenu needs a host element in the toolbar to mount into'
  );
});

test('should keep the capture-size host outside the scrolling icon strip', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const strip =
    /<div class="tb-scroll" id="nativeToolScroll">([\s\S]*?)<!-- \/\.tb-scroll -->/
      .exec(html);
  assert.ok(strip, 'the icon strip is no longer delimited as expected');
  assert.ok(
    !/id="nativeCaptureSize"/.test(strip[1]),
    'the strip is an `overflow-x: auto` container, so a popover mounted ' +
    'inside it is clipped at the strip\'s edge'
  );
});

test('should carry a Record button wired to the record action in the toolbar', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const button = /<button[^>]*id="nativeRecordBtn"[\s\S]*?<\/button>/.exec(html);
  assert.ok(button, 'no #nativeRecordBtn in the toolbar');
  assert.match(button[0], /data-action="record"/);
  assert.match(button[0], /aria-label=/);
  assert.match(button[0], /class="ico-btn/);
});

test('should place the Record button in the action group beside Screenshot', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const actions =
    /<div class="tb-actions">([\s\S]*?)<!-- \/\.tb-scroll -->/.exec(html);
  assert.ok(actions, 'the .tb-actions group is no longer delimited as expected');
  assert.match(actions[1], /id="nativeRecordBtn"/);
  assert.match(actions[1], /data-action="screenshot"/);
});

test('should style the recording state from the focus-mode palette', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.match(
    css, /#nativeRecordBtn\.recording/,
    'a recording with no visible affordance is a recording the user ' +
    'forgets is running'
  );
});

test('should load the capture vocabulary and the recorder when the capture controls mount', () => {
  const src = fs.readFileSync(path.join(WEB_ROOT, 'capture', 'capture-controls.js'), 'utf8');
  for (const module of [
    '/capture/capture-size.js',
    '/capture/capture-settings.js',
    '/capture/capture-composer.js',
    '/capture/capture-size-menu.js',
    '/capture/recorder.js',
  ]) {
    assert.ok(
      src.includes(module),
      `${module} is never loaded — focus mode can't reach it, because ` +
      'the template\'s own <script> tags are dropped by fetchTemplate'
    );
  }
});

test('should register every action the template\'s controls name', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const src = fs.readFileSync(SCRIPT, 'utf8');
  const named = new Set([...html.matchAll(/data-action="([A-Za-z0-9]+)"/g)].map((m) => m[1]));
  // A panel's toggle is registered by Panels, as `toggle<slot>` from its own file.
  const panelDir = path.join(WEB_ROOT, 'panels');
  const toggles = new Set(fs.readdirSync(panelDir, { withFileTypes: true }).filter((d) => d.isDirectory())
    .flatMap((d) => fs.readdirSync(path.join(panelDir, d.name)).filter((f) => f.endsWith('-panel.js'))
      .map((f) => fs.readFileSync(path.join(panelDir, d.name, f), 'utf8').match(/slot: '(\w+)'/))
      .filter(Boolean).map((m) => 'toggle' + m[1])));
  const missing = [...named].filter((name) => !toggles.has(name) && !src.includes(`actions.on('${name}'`));
  assert.deepEqual(missing, [], 'the template names these actions but nothing registers them, so the button is inert');
  assert.ok(named.size > 20, "the scan found the template's controls");
});
