import test from 'node:test';
import assert from 'node:assert/strict';
import { NetworkConditionForm } from '../../../Sources/Baguette/Resources/Web/panels/network/internal/network-condition-form.js';


function Form() {
  return NetworkConditionForm;
}

test('should post a chosen preset by its name alone, never its numbers', () => {
  // Network Link Conditioner's figures live in Swift. Posting the name and
  // letting the server resolve it is what keeps a second copy of them out
  // of the frontend, where the two would drift.
  const F = Form();
  assert.deepEqual(
    new F({ profile: '3g', latencyMs: 300, bandwidthKbps: 400, lossPercent: 5 }).toBody(),
    { profile: '3g' }
  );
});

test('should post offline on its own', () => {
  const F = Form();
  assert.deepEqual(
    new F({ offline: true, latencyMs: 300 }).toBody(),
    { offline: true }
  );
});

test('should post explicit numbers as numbers', () => {
  const F = Form();
  assert.deepEqual(
    new F({ latencyMs: 300, bandwidthKbps: 400, lossPercent: 5 }).toBody(),
    { latencyMs: 300, bandwidthKbps: 400, lossPercent: 5 }
  );
});

test('should leave out an unmetered bandwidth rather than send zero', () => {
  // A zero would have to mean either "unlimited" or "nothing gets through",
  // and the server would have to guess which.
  const F = Form();
  assert.deepEqual(new F({ latencyMs: 300, bandwidthKbps: 0 }).toBody(), { latencyMs: 300 });
  assert.deepEqual(new F({ latencyMs: 300, bandwidthKbps: null }).toBody(), { latencyMs: 300 });
});

test('should have no body to post when the form conditions nothing', () => {
  // The route rejects such a request, so the card should not make it.
  const F = Form();
  assert.equal(new F({}).toBody(), null);
  assert.equal(new F({ latencyMs: 0, lossPercent: 0, bandwidthKbps: 0 }).toBody(), null);
});

test('should let offline beat a preset, and a preset beat explicit numbers', () => {
  // The route takes exactly one source, so the card has to pick one before
  // posting rather than sending a body it knows will be refused.
  const F = Form();
  assert.deepEqual(new F({ offline: true, profile: '3g' }).toBody(), { offline: true });
  assert.deepEqual(new F({ profile: 'edge', lossPercent: 5 }).toBody(), { profile: 'edge' });
});

test('should describe what is applied in the words the badge shows', () => {
  const F = Form();
  assert.equal(new F({ offline: true }).describe(), 'Offline');
  assert.equal(new F({ profile: '3g' }).describe(), '3g');
  assert.equal(
    new F({ latencyMs: 300, bandwidthKbps: 400, lossPercent: 5 }).describe(),
    '300 ms · 400 kbps · 5% loss'
  );
  assert.equal(new F({ latencyMs: 300 }).describe(), '300 ms');
  assert.equal(new F({}).describe(), 'Off');
});

test('should ignore numbers that are not numbers', () => {
  // The fields are text inputs, so an empty or half-typed value arrives as
  // NaN and must not become part of the body.
  const F = Form();
  assert.equal(new F({ latencyMs: NaN, bandwidthKbps: NaN }).toBody(), null);
  assert.deepEqual(new F({ latencyMs: NaN, lossPercent: 5 }).toBody(), { lossPercent: 5 });
});

test('should read a server state payload back into a form', () => {
  // What the card hydrates from on open, so it shows what the device is
  // actually subject to rather than whatever was last typed.
  const F = Form();
  const form = F.fromState({
    active: true, latencyMs: 200, bandwidthKbps: 780, lossPercent: 0, offline: false,
  });
  assert.deepEqual(form.toBody(), { latencyMs: 200, bandwidthKbps: 780 });
});

test('should keep the preset the device reports, so its pill stays lit', () => {
  // The card posts a name and the device answers with numbers plus the
  // preset they came from. Dropping that name is what made a pressed pill
  // deselect itself the moment the response landed.
  const F = Form();
  const form = F.fromState({
    active: true, profile: '3g', latencyMs: 200, bandwidthKbps: 780, lossPercent: 0,
  });
  assert.equal(form.profile, '3g');
  assert.deepEqual(form.toBody(), { profile: '3g' });
  assert.equal(form.describe(), '3g');
});

test('should read a hand-tuned condition as custom, with no preset', () => {
  const F = Form();
  const form = F.fromState({
    active: true, profile: null, latencyMs: 317, bandwidthKbps: 411, lossPercent: 3,
  });
  assert.equal(form.profile, null);
  assert.equal(form.mode, 'custom');
  assert.deepEqual(form.toBody(), { latencyMs: 317, bandwidthKbps: 411, lossPercent: 3 });
});

test('should name which control the card shows, as its mode', () => {
  // The inputs only make sense under Custom; a preset states every number
  // it conditions, so showing three editable fields beside it invites a
  // combination the route refuses.
  const F = Form();
  assert.equal(new F({ profile: '3g' }).mode, '3g');
  assert.equal(new F({ offline: true }).mode, 'offline');
  assert.equal(new F({ latencyMs: 300 }).mode, 'custom');
  assert.equal(new F({}).mode, 'off');
});

test('should read an inactive server state back as a form that conditions nothing', () => {
  const F = Form();
  assert.equal(F.fromState({ active: false }).toBody(), null);
  assert.equal(F.fromState({ active: false }).describe(), 'Off');
});
