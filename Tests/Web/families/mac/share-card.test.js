import test from 'node:test';
import assert from 'node:assert/strict';
import { startShare, sharingOn, isDevicesList } from '../../../../Sources/Baguette/Resources/Web/families/mac/share-card.js';

// Sharing this Mac from the devices page: the card asks the Mac for a display
// the shape of this screen and opens it — as /mac/share does, which stays.

function browser({ answer = { ok: true, json: async () => ({ id: 'SHARED' }) }, search = '' } = {}) {
  const asked = [];
  return {
    asked, width: 402, height: 874, devicePixelRatio: 3, userAgent: 'iPhone', search,
    async fetch(url, init = {}) { asked.push({ url, method: init.method || 'GET', body: init.body && JSON.parse(init.body) }); return answer; },
  };
}

test('should ask the Mac for a display of this screen, with the room and use chosen, and say where it opens', async () => {
  const b = browser({ search: '?codec=h265' });
  const opens = await startShare({ room: 'moreSpace', use: 'main' }, b);
  assert.deepEqual(b.asked, [{ url: '/mac/shares', method: 'POST',
    body: { viewer: 'iPhone', width: 402, height: 874, scale: 3, room: 'moreSpace', use: 'main' } }]);
  assert.equal(opens, '/devices/SHARED?handheld=1&share=SHARED&room=moreSpace&codec=h265');
});

test('should say why when the Mac makes no display', async () => {
  const refused = browser({ answer: { ok: false, json: async () => ({ error: 'no displays left' }) } });
  await assert.rejects(startShare({ room: 'standard', use: 'extra' }, refused), /no displays left/);
  const silent = browser({ answer: { ok: false, json: async () => { throw new Error('not json'); } } });
  await assert.rejects(startShare({ room: 'standard', use: 'extra' }, silent), /The Mac didn’t make the display/);
});

test('should offer sharing only when the server shares this Mac', async () => {
  assert.equal(await sharingOn(browser({ answer: { ok: true } })), true);
  assert.equal(await sharingOn(browser({ answer: { ok: false } })), false);
  assert.equal(await sharingOn({ fetch: async () => { throw new Error('offline'); } }), false);
});

test('should show the card on the devices list, never on a device\'s own page', () => {
  assert.equal(isDevicesList('/simulators'), true);
  assert.equal(isDevicesList('/devices'), true);
  assert.equal(isDevicesList('/devices/D'), false);
  assert.equal(isDevicesList('/simulators/D'), false);
});

test('should offer sharing as a device the list shows: a display of this Mac, for this screen, ready to share', async () => {
  const { shareOffer } = await import('../../../../Sources/Baguette/Resources/Web/families/mac/share-card.js');
  const offer = shareOffer();
  assert.deepEqual(offer.listing, {
    id: 'this-mac', name: 'This Mac', state: 'ready', status: 'Ready to share', abilities: ['share'],
    kind: { platform: 'macOS', reality: 'physical', model: 'A display for this screen', os: 'macOS' },
  });
  assert.equal(offer.action, 'Share…');
  assert.equal(typeof offer.run, 'function');
});
