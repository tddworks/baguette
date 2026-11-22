'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'panels', 'defaults', 'internal', 'preference-rows.js'
);

function Rows() {
  return loadBrowserModule(MODULE_PATH).Baguette._PreferenceRows;
}

test('a read becomes one row per key, in key order, each with the control its type needs', () => {
  const rows = Rows().fromRead({
    bundleId: 'com.x',
    values: {
      username: { type: 'string', value: 'ada' },
      onboarded: { type: 'bool', value: false },
      launches: { type: 'int', value: 3 },
      ratio: { type: 'float', value: 2 },
      syncedAt: { type: 'date', value: '2026-01-02T03:04:05Z' },
    },
  });
  assert.deepEqual(rows.map((r) => [r.key, r.type, r.control]), [
    ['launches', 'int', 'text'],
    ['onboarded', 'bool', 'switch'],
    ['ratio', 'float', 'text'],
    ['syncedAt', 'date', 'text'],
    ['username', 'string', 'text'],
  ]);
  assert.equal(rows[0].text, '3');
  assert.equal(rows[1].checked, false);
  assert.equal(rows[2].text, '2');
});

test('a collection row carries the plist text the server sent, and how many entries it has', () => {
  const [flags, tags] = Rows().fromRead({
    values: {
      tags: { type: 'array', value: [{ type: 'int', value: 1 }], plist: '<array><integer>1</integer></array>' },
      flags: { type: 'dict', value: { a: { type: 'bool', value: true }, b: { type: 'bool', value: false } }, plist: '<dict/>' },
    },
  });
  assert.deepEqual([flags.control, flags.summary, flags.text], ['plist', '2 keys', '<dict/>']);
  assert.deepEqual([tags.control, tags.summary, tags.text], ['plist', '1 item', '<array><integer>1</integer></array>']);
});

test('a data row shows its size, not its bytes', () => {
  const [blob] = Rows().fromRead({ values: { blob: { type: 'data', value: 'A'.repeat(2868) } } });
  assert.deepEqual([blob.control, blob.summary], ['data', '2.1 KB']);
});

test('a read with nothing stored has no rows', () => {
  assert.deepEqual(Rows().fromRead({ bundleId: 'com.x', values: {} }), []);
  assert.deepEqual(Rows().fromRead(null), []);
});

test('a write posts the value as the type it was read as', () => {
  const R = Rows();
  assert.deepEqual(
    R.writeBody({ bundleId: 'com.x', suite: null, key: 'n', type: 'int', value: '4', relaunch: true }),
    { bundleId: 'com.x', key: 'n', type: 'int', value: '4', relaunch: true }
  );
  assert.deepEqual(
    R.writeBody({ bundleId: 'com.x', suite: 'group.x', key: 'seen', type: 'bool', value: false, relaunch: false }),
    { bundleId: 'com.x', suite: 'group.x', key: 'seen', type: 'bool', value: false, relaunch: false }
  );
});

test('a collection is written back as plist text', () => {
  assert.deepEqual(
    Rows().writeBody({ bundleId: 'com.x', key: 'tags', type: 'array', value: '<array/>', relaunch: false }).type,
    'plist'
  );
  assert.equal(
    Rows().writeBody({ bundleId: 'com.x', key: 'flags', type: 'dict', value: '<dict/>', relaunch: false }).type,
    'plist'
  );
});

test('the read, delete and groups queries name the app, the suite and the key', () => {
  const R = Rows();
  assert.equal(R.query({ bundleId: 'com.x', suite: null, plist: true }), 'bundleId=com.x&plist=1');
  assert.equal(
    R.query({ bundleId: 'com.x', suite: 'group.a&b', key: 'k y', relaunch: true }),
    'bundleId=com.x&suite=group.a%26b&key=k%20y&relaunch=1'
  );
});

test('an import posts the values of an export, or a bare map as it is', () => {
  const R = Rows();
  const values = { seen: { type: 'bool', value: false } };
  assert.deepEqual(
    R.importBody({ bundleId: 'com.x', suite: null, file: { bundleId: 'com.y', values }, relaunch: true }),
    { bundleId: 'com.x', values, relaunch: true }
  );
  assert.deepEqual(
    R.importBody({ bundleId: 'com.x', suite: 'group.x', file: values, relaunch: false }),
    { bundleId: 'com.x', suite: 'group.x', values, relaunch: false }
  );
});

test('an export file is named for the app and suite it came from', () => {
  const R = Rows();
  assert.equal(R.exportFileName({ bundleId: 'com.x', suite: null }), 'com.x.defaults.json');
  assert.equal(R.exportFileName({ bundleId: 'com.x', suite: 'group.x' }), 'com.x.group.x.defaults.json');
});

test('a failure reads as a card-level notice by its HTTP status', () => {
  const R = Rows();
  assert.deepEqual(R.notice(409, 'the simulator is not booted (run `baguette boot`)'),
    { tone: 'danger', text: 'the simulator is not booted (run `baguette boot`)', action: 'boot' });
  assert.deepEqual(R.notice(404, 'com.x has no App Group group.y'),
    { tone: 'warn', text: 'com.x has no App Group group.y', action: null });
  assert.deepEqual(R.notice(500, ''), { tone: 'danger', text: 'Request failed (500)', action: null });
});

test('a setting the running app reads but nothing stores becomes a row that says where its value comes from', () => {
  const rows = Rows().unsetFromRead({
    values: {},
    lookups: {
      answered: true,
      unset: [
        { key: 'shelf.preview', type: 'bool' },
        { key: 'unveil-ios-glass', type: 'string' },
        { key: 'volume', type: 'float', registered: { type: 'float', value: 0.5 } },
        { key: 'onboarded', type: 'bool', registered: { type: 'bool', value: true } },
      ],
    },
  });
  assert.deepEqual(rows.map((r) => [r.key, r.type, r.control, r.source]), [
    ['shelf.preview', 'bool', 'switch', 'app'],
    ['unveil-ios-glass', 'string', 'text', 'app'],
    ['volume', 'float', 'text', 'registered'],
    ['onboarded', 'bool', 'switch', 'registered'],
  ]);
  assert.equal(rows[0].checked, false);
  assert.equal(rows[1].text, '');
  assert.equal(rows[1].placeholder, "app's default");
  assert.equal(rows[2].placeholder, '0.5');
  assert.equal(rows[3].checked, true);
});

test('a setting the app only read untyped asks for its type before a value', () => {
  const [token, recent] = Rows().unsetFromRead({
    lookups: { answered: true, unset: [{ key: 'token' }, { key: 'recent', type: 'plist' }] },
  });
  assert.deepEqual([token.control, token.type], ['pick', null]);
  assert.deepEqual([recent.control, recent.type], ['pick', 'plist']);
});

test('a read tells whether the running app answered which settings it reads', () => {
  assert.equal(Rows().answered({ lookups: { answered: true, unset: [] } }), true);
  assert.equal(Rows().answered({ lookups: { answered: false } }), false);
  assert.equal(Rows().answered({ values: {} }), false);
  assert.deepEqual(Rows().unsetFromRead({ lookups: { answered: false } }), []);
});

test('an edit can ask to relaunch only when the running app would not see it', () => {
  const R = Rows();
  assert.equal(R.writeBody({ bundleId: 'com.x', key: 'k', type: 'bool', value: true, relaunch: 'whenNeeded' }).relaunch, 'whenNeeded');
  assert.equal(R.importBody({ bundleId: 'com.x', file: {}, relaunch: 'whenNeeded' }).relaunch, 'whenNeeded');
  assert.equal(R.query({ bundleId: 'com.x', key: 'k', relaunch: 'whenNeeded' }), 'bundleId=com.x&key=k&relaunch=whenNeeded');
});

test('a row the running app watches is marked live, stored or not', () => {
  const read = {
    values: { 'unveil-ios-glass': { type: 'string', value: 'Tinted' }, desk: { type: 'string', value: 'rows' } },
    lookups: { answered: true, live: ['unveil-ios-glass', 'unveil-ios-appearance'], unset: [{ key: 'unveil-ios-appearance', type: 'string' }, { key: 'shelf.preview', type: 'bool' }] },
  };
  const R = Rows();
  assert.deepEqual(R.fromRead(read).map((r) => [r.key, r.live]), [['desk', false], ['unveil-ios-glass', true]]);
  assert.deepEqual(R.unsetFromRead(read).map((r) => [r.key, r.live]), [['unveil-ios-appearance', true], ['shelf.preview', false]]);
});

test('a re-read names the stored values that changed since the last one', () => {
  const R = Rows();
  const before = R.fromRead({ values: { desk: { type: 'string', value: 'rows' }, seen: { type: 'bool', value: false } } });
  const after = R.fromRead({ values: { desk: { type: 'string', value: 'board' }, seen: { type: 'bool', value: false }, added: { type: 'int', value: 1 } } });
  assert.deepEqual(R.changedKeys(before, after), ['added', 'desk']);
  assert.deepEqual(R.changedKeys([], after), []);
});

test('a filter keeps the rows whose key or type matches, ignoring case', () => {
  const R = Rows();
  const rows = R.fromRead({ values: { 'unveil-ios-glass': { type: 'string', value: 'x' }, onboarded: { type: 'bool', value: true } } });
  assert.deepEqual(R.filter(rows, 'GLASS').map((r) => r.key), ['unveil-ios-glass']);
  assert.deepEqual(R.filter(rows, 'bool').map((r) => r.key), ['onboarded']);
  assert.equal(R.filter(rows, '  ').length, 2);
});
