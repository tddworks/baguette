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
 * be set inline from JS (`page/device-3d.js` writes `--swatch` on each element) —
 * neither can be judged from this file alone.
 */
function customProperties(css) {
  const used = new Set(
    [...css.matchAll(/var\(\s*(--nv-[\w-]+)\s*\)/g)].map((m) => m[1])
  );
  const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1]));
  return { used, defined };
}

test('every CSS comment in page/device-page.html is closed', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.equal(
    unbalancedCommentLine(css), 0,
    'unbalanced /* */ — everything from here to the next recognisable ' +
    'rule is being parsed as CSS and silently dropped'
  );
});

test('unbalancedCommentLine finds a comment closed twice', () => {
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

test('unbalancedCommentLine finds a comment never closed', () => {
  assert.equal(unbalancedCommentLine('/* opened\nand never closed\n'), 3);
});

test('every --nv-* read without a fallback is defined in the same stylesheet', () => {
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

test('the size budget defines every variable the device and panes size from', () => {
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
const PANEL_MODULES = ['page/plugins/plugins-rail.js', 'families/simulator/screens-rail.js'];

test('panel modules inject no stylesheet of their own', () => {
  for (const name of PANEL_MODULES) {
    const src = fs.readFileSync(path.join(path.dirname(TEMPLATE), '..', name), 'utf8');
    assert.ok(
      !/createElement\(\s*['"]style['"]\s*\)/.test(src),
      `${name} builds a <style> element — focus-mode CSS belongs in ` +
      'page/device-page.html under #simNativeView, where the --nv-* tokens are'
    );
  }
});

test('the focus-mode stylesheet reads no token from outside the --nv-* set', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  // `--bg` / `--text` are the standalone-preview :root in <head>, which
  // only applies under file://; `--swatch` is written per-element from
  // page/device-3d.js. Everything else must come from the theme block, because
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

test('the toolbar mounts the capture-size picker', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.match(
    html, /id="nativeCaptureSize"/,
    'CaptureSizeMenu needs a host element in the toolbar to mount into'
  );
});

test('the capture-size host sits outside the scrolling icon strip', () => {
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

test('the toolbar carries a Record button wired to __nativeRecord', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const button = /<button[^>]*id="nativeRecordBtn"[\s\S]*?<\/button>/.exec(html);
  assert.ok(button, 'no #nativeRecordBtn in the toolbar');
  assert.match(button[0], /window\.__nativeRecord/);
  assert.match(button[0], /aria-label=/);
  assert.match(button[0], /class="ico-btn/);
});

test('the Record button lives in the action group beside Screenshot', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const actions =
    /<div class="tb-actions">([\s\S]*?)<!-- \/\.tb-scroll -->/.exec(html);
  assert.ok(actions, 'the .tb-actions group is no longer delimited as expected');
  assert.match(actions[1], /id="nativeRecordBtn"/);
  assert.match(actions[1], /__nativeScreenshot/);
});

test('the recording state is styled from the focus-mode palette', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.match(
    css, /#nativeRecordBtn\.recording/,
    'a recording with no visible affordance is a recording the user ' +
    'forgets is running'
  );
});

test('page/device-page.js loads the capture vocabulary and the recorder', () => {
  const src = fs.readFileSync(SCRIPT, 'utf8');
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

test('page/device-page.js answers every toolbar indirection the template calls', () => {
  const html = markup(fs.readFileSync(TEMPLATE, 'utf8'));
  const src = fs.readFileSync(SCRIPT, 'utf8');
  const called = new Set(
    [...html.matchAll(/window\.(__native[A-Za-z0-9]+)/g)].map((m) => m[1])
  );
  const missing = [...called].filter((name) => !src.includes(`window.${name} =`));
  assert.deepEqual(
    missing, [],
    'the template calls these but page/device-page.js never assigns them, so ' +
    'the button is inert'
  );
});
