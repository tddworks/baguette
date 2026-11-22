// CarPlayFrameDefinition — parsed head-unit frame geometry.
// Pure value: viewport + screen cutout + decorative layers.
// Mount / fetch live elsewhere. Owned by CarPlay frame context;
// not DeviceKit / phone Bezel.

function isPositiveNumber(n) {
  return typeof n === 'number' && Number.isFinite(n) && n > 0;
}

function isNonNegNumber(n) {
  return typeof n === 'number' && Number.isFinite(n) && n >= 0;
}

function readRect(raw, label) {
  if (!raw || typeof raw !== 'object') {
    throw new Error(`CarPlayFrameDefinition: ${label} must be an object`);
  }
  const x = raw.x;
  const y = raw.y;
  const width = raw.width;
  const height = raw.height;
  if (!isNonNegNumber(x) || !isNonNegNumber(y)
      || !isPositiveNumber(width) || !isPositiveNumber(height)) {
    throw new Error(
      `CarPlayFrameDefinition: ${label} needs non-negative x/y and positive width/height`
    );
  }
  return { x, y, width, height };
}

function rectInsideViewport(rect, viewport) {
  return rect.x + rect.width <= viewport.width + 1e-9
      && rect.y + rect.height <= viewport.height + 1e-9;
}

function pctOf(value, total) {
  return (value / total) * 100;
}

class CarPlayFrameDefinition {
  /**
   * @param {unknown} raw JSON from definition.json
   * @returns {CarPlayFrameDefinition}
   */
  static parse(raw) {
    if (!raw || typeof raw !== 'object') {
      throw new Error('CarPlayFrameDefinition: expected an object');
    }
    if (raw.schemaVersion !== 1) {
      throw new Error('CarPlayFrameDefinition: unsupported schemaVersion');
    }
    if (typeof raw.id !== 'string' || !raw.id) {
      throw new Error('CarPlayFrameDefinition: id is required');
    }

    const vp = raw.viewport;
    if (!vp || !isPositiveNumber(vp.width) || !isPositiveNumber(vp.height)) {
      throw new Error('CarPlayFrameDefinition: viewport needs positive width/height');
    }
    const viewport = { width: vp.width, height: vp.height };

    const screenRaw = readRect(raw.screen, 'screen');
    const clipRadius = isNonNegNumber(raw.screen.clipRadius)
      ? raw.screen.clipRadius
      : 0;
    const screen = { ...screenRaw, clipRadius };
    if (!rectInsideViewport(screen, viewport)) {
      throw new Error('CarPlayFrameDefinition: screen must fit inside viewport');
    }

    const layersIn = Array.isArray(raw.layers) ? raw.layers : [];
    const layers = layersIn.map((layer, i) => {
      if (!layer || typeof layer !== 'object') {
        throw new Error(`CarPlayFrameDefinition: layers[${i}] must be an object`);
      }
      if (typeof layer.id !== 'string' || !layer.id) {
        throw new Error(`CarPlayFrameDefinition: layers[${i}].id is required`);
      }
      if (typeof layer.image !== 'string' || !layer.image) {
        throw new Error(`CarPlayFrameDefinition: layers[${i}].image is required`);
      }
      if (layer.z !== 'above' && layer.z !== 'below') {
        throw new Error(`CarPlayFrameDefinition: layers[${i}].z must be "above" or "below"`);
      }
      const rect = readRect(layer.rect, `layers[${i}].rect`);
      if (!rectInsideViewport(rect, viewport)) {
        throw new Error(`CarPlayFrameDefinition: layers[${i}].rect must fit inside viewport`);
      }
      return { id: layer.id, image: layer.image, rect, z: layer.z };
    });

    const streamRaw = raw.stream && typeof raw.stream === 'object' ? raw.stream : {};
    const defaultSize = streamRaw.defaultSize && typeof streamRaw.defaultSize === 'object'
      ? streamRaw.defaultSize
      : { width: 800, height: 450 };
    if (!isPositiveNumber(defaultSize.width) || !isPositiveNumber(defaultSize.height)) {
      throw new Error('CarPlayFrameDefinition: stream.defaultSize needs positive width/height');
    }
    const fit = streamRaw.fit === 'fill' ? 'fill' : 'contain';

    return new CarPlayFrameDefinition({
      id: raw.id,
      displayName: typeof raw.displayName === 'string' ? raw.displayName : raw.id,
      viewport,
      screen,
      layers,
      stream: {
        defaultSize: { width: defaultSize.width, height: defaultSize.height },
        fit,
      },
    });
  }

  constructor({ id, displayName, viewport, screen, layers, stream }) {
    this.id = id;
    this.displayName = displayName;
    this.viewport = viewport;
    this.screen = screen;
    this.layers = layers;
    this.stream = stream;
    Object.freeze(this.viewport);
    Object.freeze(this.screen);
    Object.freeze(this.stream.defaultSize);
    Object.freeze(this.stream);
    this.layers = layers.map((l) => {
      const copy = { ...l, rect: { ...l.rect } };
      Object.freeze(copy.rect);
      return Object.freeze(copy);
    });
    Object.freeze(this.layers);
    Object.freeze(this);
  }

  /** @returns {{ left: number, top: number, width: number, height: number }} */
  screenRectPct() {
    return this.layerRectPct(this.screen);
  }

  /**
   * @param {{ x: number, y: number, width: number, height: number }} rect
   * @returns {{ left: number, top: number, width: number, height: number }}
   */
  layerRectPct(rect) {
    const { width: vw, height: vh } = this.viewport;
    return {
      left: pctOf(rect.x, vw),
      top: pctOf(rect.y, vh),
      width: pctOf(rect.width, vw),
      height: pctOf(rect.height, vh),
    };
  }

  /**
   * Resolve a layer image URL against the definition's directory base.
   * @param {{ image: string }} layer
   * @param {string} baseUrl directory URL ending with `/`
   */
  layerImageUrl(layer, baseUrl) {
    const base = baseUrl.endsWith('/') ? baseUrl : baseUrl + '/';
    if (/^(?:[a-z]+:)?\/\//i.test(layer.image) || layer.image.startsWith('/')) {
      return layer.image;
    }
    return base + layer.image;
  }
}

export { CarPlayFrameDefinition };

