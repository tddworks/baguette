// CarPlayFrameRegistry — brand id → CarPlayFrameDefinition + asset base.
// Static files under /carplay-frames/. Plain fallback is a registry row.
import { CarPlayFrameDefinition } from './frame-definition.js';

const REGISTRY_URL = '/carplay-frames/registry.json';

class CarPlayFrameRegistry {
  static #cache = new Map();
  static #index = null;

  /** @returns {Promise<Array<{ id: string, displayName?: string, definition: string }>>} */
  static async list() {
    const index = await this.#loadIndex();
    return index.map((row) => ({
      id: row.id,
      displayName: row.displayName || row.id,
      definition: row.definition,
    }));
  }

  /**
   * @param {string} brandId
   * @returns {Promise<{ definition: object, assetBaseUrl: string }>}
   */
  static async load(brandId) {
    const id = brandId || 'plain';
    if (this.#cache.has(id)) return this.#cache.get(id);

    const index = await this.#loadIndex();
    let row = index.find((r) => r.id === id);
    if (!row) {
      row = index.find((r) => r.id === 'plain');
    }
    if (!row) {
      throw new Error(`CarPlayFrameRegistry: unknown brand "${id}" and no plain fallback`);
    }

    const Def = CarPlayFrameDefinition;

    const defUrl = row.definition.startsWith('/')
      ? row.definition
      : '/carplay-frames/' + row.definition;
    const res = await fetch(defUrl);
    if (!res.ok) {
      throw new Error(`CarPlayFrameRegistry: failed to fetch ${defUrl} (${res.status})`);
    }
    const raw = await res.json();
    const definition = Def.parse(raw);
    const assetBaseUrl = defUrl.replace(/[^/]+$/, '');
    const packed = { definition, assetBaseUrl };
    this.#cache.set(row.id, packed);
    if (id !== row.id) this.#cache.set(id, packed);
    return packed;
  }

  static async #loadIndex() {
    if (this.#index) return this.#index;
    const res = await fetch(REGISTRY_URL);
    if (!res.ok) {
      throw new Error(`CarPlayFrameRegistry: failed to fetch registry (${res.status})`);
    }
    const raw = await res.json();
    if (!Array.isArray(raw)) {
      throw new Error('CarPlayFrameRegistry: registry.json must be an array');
    }
    this.#index = raw;
    return this.#index;
  }

  /** Test hook — clear cached fetches. */
  static _resetForTests() {
    this.#cache = new Map();
    this.#index = null;
  }
}

export { CarPlayFrameRegistry };

