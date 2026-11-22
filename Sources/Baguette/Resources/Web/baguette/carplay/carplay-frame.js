// CarPlayFrame — mounts a CarPlayFrameDefinition into a container
// (typically #nativeCarPlayFrame). Returns screenArea + canvas for
// StreamSession / Screen.bindDOM. Decorative layers are pointer-events
// none. Not phone Bezel / DeviceKit.

class CarPlayFrame {
  /**
   * @param {object} definition CarPlayFrameDefinition
   * @param {{ assetBaseUrl?: string }} [opts]
   */
  constructor(definition, opts) {
    this.definition = definition;
    this.assetBaseUrl = (opts && opts.assetBaseUrl) || '';
    this.container = null;
    this.wrapper = null;
    this.screenArea = null;
    this.canvas = null;
  }

  /**
   * @param {HTMLElement} container
   * @returns {{ screenArea: HTMLElement, canvas: HTMLCanvasElement, detach: () => void }}
   */
  mount(container) {
    if (this.wrapper) {
      throw new Error('CarPlayFrame: already mounted');
    }
    if (!container) {
      throw new Error('CarPlayFrame: container is required');
    }
    const doc = container.ownerDocument || globalThis.document;
    if (!doc || !doc.createElement) {
      throw new Error('CarPlayFrame: no document available');
    }

    const def = this.definition;
    container.innerHTML = '';

    const wrapper = doc.createElement('div');
    wrapper.className = 'carplay-frame__wrapper';
    wrapper.style.cssText =
      'position:relative;display:block;width:100%;height:100%;'
      + `aspect-ratio:${def.viewport.width} / ${def.viewport.height};`;

    const below = def.layers.filter((l) => l.z === 'below');
    const above = def.layers.filter((l) => l.z === 'above');

    for (const layer of below) {
      wrapper.appendChild(this.#layerImg(doc, layer));
    }

    const screenArea = doc.createElement('div');
    screenArea.className = 'carplay-frame__screen';
    screenArea.tabIndex = 0;
    screenArea.style.cssText =
      'position:absolute;overflow:hidden;cursor:crosshair;z-index:2;outline:none;';
    const sp = def.screenRectPct();
    screenArea.style.left = sp.left + '%';
    screenArea.style.top = sp.top + '%';
    screenArea.style.width = sp.width + '%';
    screenArea.style.height = sp.height + '%';
    const cr = def.screen.clipRadius || 0;
    if (cr > 0) {
      const hPct = (cr / def.screen.width) * 100;
      const vPct = (cr / def.screen.height) * 100;
      screenArea.style.borderRadius = `${hPct}% / ${vPct}%`;
    }

    const canvas = doc.createElement('canvas');
    canvas.id = 'nativeCarPlayCanvas';
    canvas.width = def.stream.defaultSize.width;
    canvas.height = def.stream.defaultSize.height;
    canvas.style.cssText =
      'display:block;width:100%;height:100%;background:#000;pointer-events:none;'
      + `object-fit:${def.stream.fit};image-rendering:high-quality;`;
    screenArea.appendChild(canvas);
    wrapper.appendChild(screenArea);

    for (const layer of above) {
      wrapper.appendChild(this.#layerImg(doc, layer));
    }

    container.appendChild(wrapper);
    if (container.classList && container.classList.add) {
      container.classList.add('carplay-frame--mounted');
    }

    this.container = container;
    this.wrapper = wrapper;
    this.screenArea = screenArea;
    this.canvas = canvas;

    return {
      screenArea,
      canvas,
      detach: () => this.detach(),
    };
  }

  /** Alias for mount return shape (arena graft). */
  ports() {
    return { screenArea: this.screenArea, canvas: this.canvas };
  }

  detach() {
    if (!this.container) return;
    if (this.wrapper && this.wrapper.parentNode === this.container) {
      this.container.removeChild(this.wrapper);
    } else {
      this.container.innerHTML = '';
    }
    if (this.container.classList && this.container.classList.remove) {
      this.container.classList.remove('carplay-frame--mounted');
    }
    this.container = null;
    this.wrapper = null;
    this.screenArea = null;
    this.canvas = null;
  }

  #layerImg(doc, layer) {
    const img = doc.createElement('img');
    img.alt = '';
    img.draggable = false;
    img.setAttribute('data-layer', layer.id);
    img.setAttribute('aria-hidden', 'true');
    img.src = this.definition.layerImageUrl(layer, this.assetBaseUrl);
    const pct = this.definition.layerRectPct(layer.rect);
    const z = layer.z === 'above' ? 3 : 1;
    img.style.cssText =
      'position:absolute;pointer-events:none;display:block;z-index:' + z + ';'
      + `left:${pct.left}%;top:${pct.top}%;width:${pct.width}%;height:${pct.height}%;`
      + 'object-fit:fill;';
    return img;
  }
}

export { CarPlayFrame };

