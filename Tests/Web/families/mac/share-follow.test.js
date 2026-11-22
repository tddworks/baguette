import test from 'node:test';
import assert from 'node:assert/strict';
import { followShare } from '../../../../Sources/Baguette/Resources/Web/families/mac/share-follow.js';
import { pageShare } from '../../../../Sources/Baguette/Resources/Web/families/mac/share.js';

// A share's page follows its viewer: when the device turns, the display is
// made again in the new shape and the page reloads onto it; leaving the page
// ends the share. Each step through the browser, played here.

function browser({ width = 402, height = 874, answers = [] } = {}) {
  const listeners = {}, timers = [], requests = [];
  let reloads = 0;
  const b = {
    width, height, requests, devicePixelRatio: 3, userAgent: 'iPhone',
    get reloads() { return reloads; },
    location: { reload: () => { reloads += 1; } },
    on: (event, fn) => { listeners[event] = fn; },
    fire: (event) => listeners[event](),
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    clearTimeout: () => {},
    /** The settle timer runs out. */
    settle: async () => { await timers.pop()(); },
    async fetch(url, init) { requests.push({ url, method: init.method, body: init.body && JSON.parse(init.body) }); return { ok: answers.length ? answers.shift() : true }; },
  };
  return b;
}

const share = { id: 'SHARED', room: 'moreSpace' };

test('should make the display again in the turned shape, then reload onto it', async () => {
  const b = browser();
  followShare(share, pageShare(), b);
  Object.assign(b, { width: 874, height: 402 });
  b.fire('resize');
  await b.settle();
  assert.deepEqual(b.requests.map((r) => [r.url, r.method, r.body.width, r.body.height, r.body.room]),
    [['/mac/shares/SHARED', 'PUT', 874, 402, 'moreSpace']]);
  assert.equal(b.reloads, 1);
});

test('should leave the display as it is when the screen only wobbles, as a browser bar comes and goes', async () => {
  const b = browser();
  followShare(share, pageShare(), b);
  b.height = 860;
  b.fire('resize');
  await b.settle();
  assert.equal(b.requests.length, 0);
});

test('should ask again on the next turn when the Mac refused the last', async () => {
  const b = browser({ answers: [false, true] });
  followShare(share, pageShare(), b);
  Object.assign(b, { width: 874, height: 402 });
  b.fire('resize');
  await b.settle();
  assert.equal(b.reloads, 0);
  b.fire('resize');
  await b.settle();
  assert.equal(b.requests.length, 2);
  assert.equal(b.reloads, 1);
});

test('should make it once more when the device turned again while it was being made', async () => {
  const b = browser();
  const realFetch = b.fetch;
  b.fetch = async (url, init) => { const answer = await realFetch(url, init); if (b.requests.length === 1) Object.assign(b, { width: 402, height: 874 }); return answer; };
  followShare(share, pageShare(), b);
  Object.assign(b, { width: 874, height: 402 });
  b.fire('resize');
  await b.settle();
  assert.deepEqual(b.requests.map((r) => r.body.width), [874, 402]);
  assert.equal(b.reloads, 1);
});

test('should end the share when the page is left, and keep it when the page reloads itself', () => {
  const left = browser();
  followShare(share, pageShare(), left);
  left.fire('pagehide');
  assert.deepEqual(left.requests.map((r) => [r.url, r.method]), [['/mac/shares/SHARED', 'DELETE']]);

  const reloading = browser();
  const own = pageShare();
  followShare(share, own, reloading);
  own.reloadKeepingShare(reloading.location);
  reloading.fire('pagehide');
  assert.equal(reloading.requests.length, 0);
});
