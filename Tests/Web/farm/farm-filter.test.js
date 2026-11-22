import test from 'node:test';
import assert from 'node:assert/strict';
import { FarmFilter as Filter } from '../../../Sources/Baguette/Resources/Web/farm/farm-filter.js';

function FarmFilter() { return Filter; }

function device(overrides) {
  return { platform: 'iphone', runtime: '26.4', uiState: 'live', name: 'A', udid: 'U', ...overrides };
}

test('should include every known option in each facet at first', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4', '18.4'] });
  const devices = [
    device({ platform: 'iphone', runtime: '26.4', uiState: 'live' }),
    device({ platform: 'watch', runtime: '18.4', uiState: 'off' }),
  ];
  assert.deepEqual(filter.apply(devices), devices);
});

test('should remove an option on a toggle and add it back on the next', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [device({ platform: 'iphone' }), device({ platform: 'ipad' })];

  filter.toggle('platforms', 'ipad');
  assert.deepEqual(filter.apply(devices).map((d) => d.platform), ['iphone']);

  filter.toggle('platforms', 'ipad');
  assert.deepEqual(filter.apply(devices).map((d) => d.platform).sort(), ['ipad', 'iphone']);
});

test('should match a search against name, udid, runtime and platform whatever the case', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [
    device({ name: 'iPhone 17 Pro', udid: 'ABC-123' }),
    device({ name: 'iPhone 17 Pro Max', udid: 'DEF-456' }),
  ];
  filter.search = 'def';
  assert.deepEqual(filter.apply(devices).map((d) => d.udid), ['DEF-456']);
});

test('should include a newly discovered runtime when it is seeded', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  filter.seedRuntimes(['18.4']);
  const devices = [device({ runtime: '18.4' })];
  assert.deepEqual(filter.apply(devices), devices);
});

test('should exclude a runtime never seeded even when platforms and states are inclusive', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [device({ runtime: '99.0' })];
  assert.deepEqual(filter.apply(devices), []);
});

test('should count devices per platform and per state', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [
    device({ platform: 'iphone', uiState: 'live' }),
    device({ platform: 'iphone', uiState: 'boot' }),
    device({ platform: 'ipad', uiState: 'live' }),
  ];
  assert.deepEqual(filter.counts(devices), {
    platform: { iphone: 2, ipad: 1 },
    state: { live: 2, boot: 1 },
  });
});
