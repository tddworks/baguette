// sim-3d.js — live server-rendered 3D simulator stream.
(function () {
  'use strict';

  function Sim3DPanel() {
    this.host = null;
    this.stage = null;
    // The live 3D frame, painted by the shared StreamSession. Public on
    // purpose: it is what a recorder captures (`canvas.captureStream()`)
    // for a 3D screen recording. Non-null from `mountStage()` until
    // `detach()`, i.e. for the whole time the stream is running.
    this.canvas = null;
    this.udid = '';
    this.model = null;
    this.session = null;
    this.format = 'mjpeg';
    this.background = '#f1f3f6';
    this.rotation = { x: -8, y: 18, z: 0 };
    this.zoom = 1;
    this.mode = 'pose';
    this.variants = {};
    this.screenGlass = false;
    // The size/fit/background the user picked in the toolbar, shared with
    // every other capture surface. `null` on pages that don't load the
    // capture modules — saving still works, it just tracks the live frame.
    this.captureSettings = null;
    this.saving = false;
    this.deviceSize = { width: 1, height: 1 };
    this.onFps = null;
    this.pointer = null;
    this.interactiveScreen = null;
    // Where the screen mesh currently lands in the rendered image
    // (server-pushed `screen_quad`, normalized to the output frame) —
    // lets Interact mode map a canvas click onto the device screen at
    // any camera pose instead of treating the whole canvas as the
    // screen. `null` until the first message arrives.
    this.screenQuad = null;
    this.restartTimer = null;
    this.cameraFrame = 0;
    this.generation = 0;
    this.onMouseMove = (event) =>
      this.pointerMove('mouse', event.clientX, event.clientY, event);
    this.onMouseUp = (event) =>
      this.pointerUp('mouse', event.clientX, event.clientY, event);
    this.onTouchMove = (event) => this.touchMove(event);
    this.onTouchEnd = (event) => this.touchEnd(event);
    this.onTouchCancel = () => this.cancelPointer();
  }

  Sim3DPanel.prototype.attach = async function (host, stage, udid, options) {
    this.host = host;
    this.stage = stage;
    this.udid = udid;
    options = options || {};
    this.deviceSize = options.deviceSize || this.deviceSize;
    this.onFps = options.onFps || null;
    this.format = options.format === 'avcc' ? 'avcc' : 'mjpeg';
    this.background = options.background || this.background;
    this.renderLoading('Loading 3D model…');
    try {
      const targetPath = (u, rest) => (window.BaguetteTarget
          ? window.BaguetteTarget.path(u, rest)
          : '/simulators/' + encodeURIComponent(u) + rest);
      const response = await fetch(
          targetPath(udid, '/3d-model.json'),
          { cache: 'no-store' }
      );
      if (!response.ok) {
        throw new Error(response.status === 404
          ? 'No 3D model is installed for this simulator.'
          : 'Could not load model metadata.');
      }
      this.model = await response.json();
      if (this.model && this.model.model === null && Array.isArray(this.model.models)) {
        const stored = localStorage.getItem('baguette.twin.model.' + udid);
        const choices = this.model.models;
        const pick = choices.find((m) => m.id === stored);
        if (pick) {
          this.modelPick = pick.id;
          this.model = { id: pick.id, displayName: pick.displayName, variantSets: [] };
        } else {
          this.renderModelPicker(this.model.hardware || '', choices);
          return;
        }
      }
      (this.model.variantSets || []).forEach((set) => {
        this.variants[set.id] = set.default;
      });
      this.renderControls();
      this.mountStage();
      this.start();
    } catch (error) {
      this.renderError(error.message || String(error));
    }
  };

  Sim3DPanel.prototype.mountStage = function () {
    if (!this.stage) return;
    this.stage.innerHTML =
        '<canvas class="r3d-live-canvas" aria-label="Live 3D simulator"></canvas>' +
        '<div class="r3d-stage-tools" aria-label="3D interaction mode">' +
          '<button type="button" class="active" data-stage-mode="pose">Pose</button>' +
          '<button type="button" data-stage-mode="interact">Interact</button>' +
          '<button type="button" data-stage-reset title="Reset to front">Reset</button>' +
        '</div>' +
        '<button type="button" class="r3d-inspector-toggle" ' +
          'title="Show 3D inspector" aria-label="Show 3D inspector" ' +
          'onclick="window.__nativeToggle3DInspector && window.__nativeToggle3DInspector()">' +
          '<span aria-hidden="true">☷</span></button>' +
        '<div class="r3d-live-state" data-role="live-state">' +
          '<span class="r3d-spinner"></span><span>Loading model…</span>' +
        '</div>';
    this.canvas = this.stage.querySelector('canvas');
    this.canvas.addEventListener('mousedown', (event) => {
      if (event.button === 0 && this.mode === 'pose') {
        this.pointerDown('mouse', event.clientX, event.clientY, event);
      }
    });
    this.canvas.addEventListener('touchstart', (event) => {
      if (this.mode !== 'pose') return;
      if (event.changedTouches.length !== 1) return;
      const touch = event.changedTouches[0];
      this.pointerDown(touch.identifier, touch.clientX, touch.clientY, event);
    }, { passive: false });
    this.canvas.addEventListener('dblclick', () => this.resetCamera());
    this.canvas.addEventListener('wheel', (event) => this.zoomCamera(event), {
      passive: false,
    });
    this.stage.querySelectorAll('[data-stage-mode]').forEach((button) => {
      button.addEventListener('click', () => this.setMode(button.dataset.stageMode));
    });
    this.stage.querySelector('[data-stage-reset]').addEventListener(
        'click', () => this.resetCamera()
    );
    const transport = new window.Baguette._Transport({
      send: (payload) => this.send(payload),
    });
    this.interactiveScreen = new window.Baguette._Screen({
      rect: { width: this.deviceSize.width, height: this.deviceSize.height },
    }, transport);
    this.setMode(this.mode);
  };

  Sim3DPanel.prototype.start = function () {
    this.stop();
    if (!this.canvas || !this.model) return;
    this.screenQuad = null;
    const generation = ++this.generation;
    const size = this.outputSize();
    const params = new URLSearchParams({
      rotation: [this.rotation.x, this.rotation.y, this.rotation.z].join(','),
      width: String(size.width),
      height: String(size.height),
      fit: 'cover',
      background: this.background,
    });
    if (this.screenGlass) params.set('screenGlass', 'true');
    if (this.modelPick) params.set('model', this.modelPick);
    Object.keys(this.variants).forEach((set) => {
      params.append('variant', set + ':' + this.variants[set]);
    });
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const base = (window.BaguetteTarget
        ? window.BaguetteTarget.path(this.udid, '')
        : '/simulators/' + encodeURIComponent(this.udid));
    const path = base + '/stream.3d.' + this.format + '?' + params.toString();
    this.setState('Loading model…', true);
    this.session = new window.StreamSession({
      udid: this.udid,
      format: this.format,
      canvas: this.canvas,
      url: scheme + '//' + location.host + path,
      onFps: (fps) => {
        if (generation === this.generation && this.onFps && fps > 0) {
          this.onFps(fps);
        }
      },
      onLog: (message, error) => {
        if (error && generation === this.generation) {
          this.setState(message || '3D decode failed', false, true);
        }
      },
      onText: (envelope) => {
        if (generation !== this.generation) return false;
        if (envelope && envelope.type === 'screen_quad') {
          this.screenQuad = window.Baguette._ScreenQuad.fromCorners(envelope.corners);
          return true;
        }
        if (envelope && envelope.error) {
          this.setState(envelope.error, false, true);
          return true;
        }
        return false;
      },
      onOpen: () => {
        if (generation !== this.generation) return;
        this.setState('Waiting for frame…', true);
        this.sendCamera();
      },
      onPaint: () => {
        if (generation === this.generation) this.setState('', false);
      },
      onClose: () => {
        if (generation === this.generation && this.canvas &&
          !this.canvas.hasAttribute('data-painted')) {
          this.setState('3D stream disconnected', false, true);
        }
      },
      onError: () => {
        if (generation === this.generation) {
          this.setState('3D stream failed', false, true);
        }
      },
    });
    this.session.start();
  };

  Sim3DPanel.prototype.stop = function () {
    this.cancelPointer();
    this.generation += 1;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    if (this.cameraFrame) cancelAnimationFrame(this.cameraFrame);
    this.cameraFrame = 0;
    if (this.session) this.session.stop();
    this.session = null;
  };

  Sim3DPanel.prototype.setFormat = function (format) {
    const next = format === 'avcc' ? 'avcc' : 'mjpeg';
    if (this.format === next) return;
    this.format = next;
    this.renderControls();
    this.start();
  };

  Sim3DPanel.prototype.setBackground = function (background) {
    if (!/^#[0-9a-f]{6}$/i.test(background || '') ||
        background.toLowerCase() === this.background.toLowerCase()) return;
    this.background = background;
    this.scheduleRestart(0);
  };

  /**
   * Adopt the toolbar's CaptureSettings.
   *
   * The stream keeps the stage's own SHAPE whatever the pick — framing
   * a saved 3D image is the camera's job, and reshaping the live view
   * to the target aspect makes it worse, not better. What the pick can
   * change is the stream's DENSITY (`streamBudget`), and only across
   * the native/sized line. So a restart happens at most once per
   * session, on the first size the user picks, not on every change:
   * switching between two sized presets, or touching fit, background
   * or the bezel, leaves the stream alone.
   */
  Sim3DPanel.prototype.setCaptureSettings = function (settings) {
    const before = Sim3DPanel.streamBudget(this.captureSettings);
    this.captureSettings = settings || null;
    if (!this.session) return;
    if (Sim3DPanel.streamBudget(this.captureSettings) === before) return;
    this.start();
  };

  Sim3DPanel.prototype.detach = function () {
    this.stop();
    if (this.interactiveScreen) this.interactiveScreen.detach();
    this.interactiveScreen = null;
    if (this.host) this.host.innerHTML = '';
    if (this.stage) this.stage.innerHTML = '';
    this.host = null;
    this.stage = null;
    this.canvas = null;
  };

  Sim3DPanel.prototype.send = function (payload) {
    return !!(this.session && this.session.send(payload));
  };

  Sim3DPanel.prototype.scheduleRestart = function (delay) {
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start();
    }, delay == null ? 80 : delay);
  };

  Sim3DPanel.prototype.renderLoading = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty"><span class="r3d-spinner"></span><span></span></div>';
    this.host.querySelector('.r3d-empty span:last-child').textContent = message;
  };

  Sim3DPanel.prototype.renderError = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty r3d-error"><strong>3D stream unavailable</strong>' +
        '<span data-role="message"></span>' +
        '<button type="button" data-role="retry">Try Again</button></div>';
    this.host.querySelector('[data-role="message"]').textContent = message;
    this.host.querySelector('[data-role="retry"]').addEventListener(
        'click', () => this.attach(this.host, this.stage, this.udid, {
          deviceSize: this.deviceSize, onFps: this.onFps, format: this.format,
        })
    );
  };

  /// No installed USDZ matches this phone's hardware id. Baguette
  /// never substitutes a look-alike on its own — the user picks,
  /// the pick rides `?model=` and is remembered per device.
  Sim3DPanel.prototype.renderModelPicker = function (hardware, choices) {
    if (!this.host) return;
    const options = choices.map((m) =>
        '<button type="button" data-model-pick="' + m.id + '">' +
        (window.escapeHTML ? window.escapeHTML(m.displayName) : m.displayName) +
        '</button>').join('');
    this.host.innerHTML =
        '<div class="r3d-empty"><strong>Pick a model for this device</strong>' +
        '<span>No installed 3D model matches ' + hardware +
        '. Choose one to stand in:</span>' +
        '<div data-role="model-choices" style="display:flex;flex-direction:column;gap:6px;margin-top:10px">' +
        (options || '<em>No models installed</em>') + '</div></div>';
    this.host.querySelectorAll('[data-model-pick]').forEach((btn) => {
      btn.addEventListener('click', () => {
        localStorage.setItem('baguette.twin.model.' + this.udid, btn.dataset.modelPick);
        this.attach(this.host, this.stage, this.udid, {
          deviceSize: this.deviceSize, onFps: this.onFps, format: this.format,
        });
      });
    });
  };

  Sim3DPanel.prototype.renderControls = function () {
    const variants = (this.model.variantSets || []).map((set) => {
      const choices = (set.choices || []).map((choice) => {
        const color = choice.previewColor
          ? '<i style="--swatch:' + escapeAttr(choice.previewColor) + '"></i>'
          : '';
        return '<button type="button" class="r3d-choice" data-set="' +
            escapeAttr(set.id) + '" data-choice="' + escapeAttr(choice.id) + '">' +
            color + '<span>' + escapeHTML(choice.displayName) + '</span></button>';
      }).join('');
      return '<section class="r3d-section"><label>' +
          escapeHTML(set.displayName) + '</label><div class="r3d-choices">' +
          choices + '</div></section>';
    }).join('');
    this.host.innerHTML =
        '<div class="r3d-live-summary"><strong>' +
          escapeHTML(this.model.displayName) + '</strong><span>Live ' +
          escapeHTML(this.format.toUpperCase()) + '</span></div>' +
        variants +
        '<section class="r3d-section"><label>Screen</label>' +
          '<div class="r3d-presets">' +
            '<button type="button" data-role="glass-toggle">Glass reflections</button>' +
          '</div>' +
        '</section>' +
        '<section class="r3d-section"><label>View</label>' +
          '<div class="r3d-presets">' +
            '<button type="button" data-preset="-8,18,0">Hero</button>' +
            '<button type="button" data-preset="0,0,0">Front</button>' +
            '<button type="button" data-preset="0,38,0">Side</button>' +
            '<button type="button" data-preset="-28,28,0">Top</button>' +
          '</div>' +
        '</section>' +
        '<details class="r3d-advanced"><summary>Advanced rotation</summary>' +
          '<div class="r3d-advanced-body">' +
            rangeRow('x', 'Tilt', -45, 45, this.rotation.x) +
            rangeRow('y', 'Turn', -80, 80, this.rotation.y) +
            rangeRow('z', 'Roll', -45, 45, this.rotation.z) +
          '</div></details>' +
        '<div class="r3d-footer">' +
          '<button type="button" class="r3d-download" data-role="download">Save Frame</button>' +
        '</div>';

    this.host.querySelectorAll('.r3d-choice').forEach((button) => {
      button.classList.toggle(
          'active', this.variants[button.dataset.set] === button.dataset.choice
      );
      button.addEventListener('click', () => {
        this.variants[button.dataset.set] = button.dataset.choice;
        this.host.querySelectorAll(
            '.r3d-choice[data-set="' + cssEscape(button.dataset.set) + '"]'
        ).forEach((candidate) => candidate.classList.toggle(
            'active', candidate.dataset.choice === button.dataset.choice
        ));
        this.scheduleRestart(0);
      });
    });
    this.host.querySelectorAll('[data-axis]').forEach((range) => {
      const output = this.host.querySelector(
          '[data-value="' + range.dataset.axis + '"]'
      );
      range.addEventListener('input', () => {
        this.rotation[range.dataset.axis] = Number(range.value);
        if (output) output.textContent = range.value + '°';
        this.sendCamera();
      });
    });
    this.host.querySelectorAll('[data-preset]').forEach((button) => {
      button.addEventListener('click', () => {
        const values = button.dataset.preset.split(',').map(Number);
        ['x', 'y', 'z'].forEach((axis, index) => {
          this.rotation[axis] = values[index];
          const range = this.host.querySelector('[data-axis="' + axis + '"]');
          const output = this.host.querySelector('[data-value="' + axis + '"]');
          if (range) range.value = String(values[index]);
          if (output) output.textContent = values[index] + '°';
        });
        this.sendCamera();
      });
    });
    this.host.querySelectorAll('[data-mode]').forEach((button) => {
      button.addEventListener('click', () => this.setMode(button.dataset.mode));
    });
    const glassToggle = this.host.querySelector('[data-role="glass-toggle"]');
    glassToggle.classList.toggle('active', this.screenGlass);
    glassToggle.addEventListener('click', () => {
      this.screenGlass = !this.screenGlass;
      glassToggle.classList.toggle('active', this.screenGlass);
      this.scheduleRestart(0);
    });
    this.host.querySelector('[data-role="download"]').addEventListener(
        'click', () => this.download()
    );
  };

  Sim3DPanel.prototype.setMode = function (mode) {
    this.mode = mode === 'interact' ? 'interact' : 'pose';
    this.cancelPointer();
    if (this.stage) this.stage.dataset.mode = this.mode;
    if (this.interactiveScreen && this.canvas) {
      if (this.mode === 'interact') {
        this.interactiveScreen.bindInteraction({
          element: this.canvas,
          overlayHost: this.stage,
          mapClientPoint: (clientX, clientY) => this.mapClientPoint(clientX, clientY),
        });
      } else {
        this.interactiveScreen.unbindInteraction();
      }
    }
    const selector = '[data-mode], [data-stage-mode]';
    document.querySelectorAll(selector).forEach((candidate) => {
      const value = candidate.dataset.mode || candidate.dataset.stageMode;
      candidate.classList.toggle('active', value === this.mode);
    });
  };

  /**
   * How a RECORDING should place the stage canvas into the picked size.
   *
   * A screenshot in 3D re-renders server-side at the exact size, so it
   * is always framed. A recording can't — BrowserRecorder composites the
   * stage canvas frame by frame as it arrives. The stage is a viewport
   * onto a scene: a device standing in the middle of empty margins. So
   * letterboxing the WHOLE stage into a tall App Store canvas shrinks
   * the device into the emptiness instead of cropping the emptiness
   * away, which is how a 6.9" recording came out as a small phone adrift
   * in bands.
   *
   * Crop as far as the target allows, and no further: `cover` when the
   * target is narrower than the stage — it eats the side margins and
   * keeps full height — and `contain` when it is wider, because past
   * that point there is no more device to show, only bars, and cropping
   * into the device is worse than a bar beside it.
   *
   * Pure and static so the arithmetic is testable without a canvas.
   *
   * @param {object|null} settings  a CaptureSettings
   * @param {{width:number,height:number}} stage  the stage canvas
   * @returns {'cover'|'contain'}
   */
  Sim3DPanel.recordingFit = function (settings, stage) {
    const size = settings && settings.size;
    const width = (stage && stage.width) || 0;
    const height = (stage && stage.height) || 0;
    if (!size || size.isNative || !(width > 0) || !(height > 0)) return 'contain';
    const target = size.resolve(width, height);
    if (!target || !(target.width > 0) || !(target.height > 0)) return 'contain';
    return target.width / target.height < width / height ? 'cover' : 'contain';
  };

  /**
   * How many pixels the live stream may spend on its long side.
   *
   * 1600 ordinarily — enough to look right on a retina stage without
   * asking the encoder for more than the view can show. More once the
   * user has picked an output size, because a picked size is a claim
   * about quality and a 3D RECORDING pays for the stream's density
   * twice over: `recordingFit` crops the stage to the target's shape,
   * so a 6.9" crop of a 1600 × 1129 stage is only 521 px wide and gets
   * upscaled 2.5x to reach 1290. A denser stream is nearly free —
   * measured on an M-series Mac, the RealityKit render takes 0.67s at
   * 924 x 652 and 0.72s at 3200 x 2258, 12x the area for 7% more wall
   * clock — and the live view is unaffected: same shape, shown at the
   * same size by `object-fit: contain`, just sharper.
   *
   * Screenshots don't need any of this. They re-render server-side at
   * the exact size, off the stream entirely.
   */
  Sim3DPanel.streamBudget = function (settings) {
    const size = settings && settings.size;
    return size && !size.isNative ? 2560 : 1600;
  };

  /**
   * The live stream's pixel box: always the stage's own SHAPE, at a
   * density the picked size decides.
   *
   * At `native` the stream matches the stage's device pixels, bounded
   * by [480, 1600] — enough to look right, no more than the view can
   * show. Once a size is picked the long side takes the WHOLE budget,
   * supersampling the stage rather than merely being allowed to match
   * it, because a recording keeps only the cropped fraction of these
   * pixels. Downsampling the result for display is antialiasing, so
   * the live view gets better, not worse.
   *
   * Scaling rather than clamping each side is the other half. The
   * per-side clamp this replaces turned a 3800 x 1240 stage into
   * 1600 x 1240 — aspect 3.07 rendered as 1.29 — so the camera framed
   * a different scene than the stage was showing and `object-fit:
   * contain` letterboxed the difference back out.
   *
   * Pure and static so the arithmetic is testable without a canvas.
   */
  Sim3DPanel.streamBox = function (stage, settings) {
    const width = (stage && stage.width) || 960;
    const height = (stage && stage.height) || 960;
    const long = Math.max(width, height);
    if (!(long > 0)) return { width: 960, height: 960 };
    const budget = Sim3DPanel.streamBudget(settings);
    const size = settings && settings.size;
    const target = size && !size.isNative
      ? budget
      : Math.max(480, Math.min(budget, long));
    const scale = target / long;
    return {
      width: Math.round(width * scale),
      height: Math.round(height * scale),
    };
  };

  Sim3DPanel.prototype.outputSize = function () {
    const rect = this.stage ? this.stage.getBoundingClientRect() : null;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    return Sim3DPanel.streamBox({
      width: Math.round((rect && rect.width || 960) * ratio),
      height: Math.round((rect && rect.height || 960) * ratio),
    }, this.captureSettings);
  };

  Sim3DPanel.prototype.setState = function (message, busy, error) {
    if (!this.stage) return;
    const state = this.stage.querySelector('[data-role="live-state"]');
    if (!state) return;
    state.hidden = !message;
    state.toggleAttribute('data-error', !!error);
    const label = state.querySelector('span:last-child');
    if (label) label.textContent = message || '';
    const spinner = state.querySelector('.r3d-spinner');
    if (spinner) spinner.hidden = !busy;
    if (!message && this.canvas) this.canvas.setAttribute('data-painted', '');
  };

  Sim3DPanel.prototype.pointerDown = function (id, clientX, clientY, event) {
    if (this.mode !== 'pose' || !this.canvas ||
        !this.canvas.hasAttribute('data-painted')) return;
    event.preventDefault();
    this.cancelPointer();
    this.pointer = {
      id: id, x: clientX, y: clientY, time: performance.now(),
      action: event.altKey ? 'zoom' : 'orbit',
      zoom: this.zoom,
      rotation: { x: this.rotation.x, y: this.rotation.y, z: this.rotation.z },
    };
    if (id === 'mouse') {
      document.addEventListener('mousemove', this.onMouseMove, { passive: false });
      document.addEventListener('mouseup', this.onMouseUp, { passive: false });
    } else {
      document.addEventListener('touchmove', this.onTouchMove, { passive: false });
      document.addEventListener('touchend', this.onTouchEnd, { passive: false });
      document.addEventListener('touchcancel', this.onTouchCancel);
    }
  };

  Sim3DPanel.prototype.pointerMove = function (id, clientX, clientY, event) {
    if (!this.pointer || id !== this.pointer.id || this.mode !== 'pose') return;
    event.preventDefault();
    if (this.pointer.action === 'zoom') {
      this.zoom = Math.max(0.5, Math.min(3,
          this.pointer.zoom * Math.exp((this.pointer.y - clientY) * 0.008)));
      this.sendCamera();
      return;
    }
    this.rotation.x = Math.max(-80, Math.min(80,
        this.pointer.rotation.x + (clientY - this.pointer.y) * 0.35));
    this.rotation.y = Math.max(-180, Math.min(180,
        this.pointer.rotation.y + (clientX - this.pointer.x) * 0.35));
    this.syncCameraControls();
    this.sendCamera();
  };

  Sim3DPanel.prototype.pointerUp = function (id, clientX, clientY, event) {
    if (!this.pointer || id !== this.pointer.id) return;
    event.preventDefault();
    this.cancelPointer();
  };

  Sim3DPanel.prototype.touchMove = function (event) {
    if (!this.pointer || this.pointer.id === 'mouse') return;
    const touch = Array.from(event.touches).find(
        (candidate) => candidate.identifier === this.pointer.id
    );
    if (touch) this.pointerMove(
        touch.identifier, touch.clientX, touch.clientY, event
    );
  };

  Sim3DPanel.prototype.touchEnd = function (event) {
    if (!this.pointer || this.pointer.id === 'mouse') return;
    const touch = Array.from(event.changedTouches).find(
        (candidate) => candidate.identifier === this.pointer.id
    );
    if (touch) this.pointerUp(
        touch.identifier, touch.clientX, touch.clientY, event
    );
  };

  Sim3DPanel.prototype.cancelPointer = function () {
    this.pointer = null;
    document.removeEventListener('mousemove', this.onMouseMove);
    document.removeEventListener('mouseup', this.onMouseUp);
    document.removeEventListener('touchmove', this.onTouchMove);
    document.removeEventListener('touchend', this.onTouchEnd);
    document.removeEventListener('touchcancel', this.onTouchCancel);
  };

  /**
   * canvas-pixel click → device-screen point, for Interact mode.
   * Maps through the last `screen_quad` the server pushed instead of
   * treating the whole canvas as a 1:1 screen crop — the rendered
   * screen is a rotated, perspective-foreshortened quad sitting inside
   * a larger canvas (device body/bezel/background/cover-glass).
   */
  Sim3DPanel.prototype.mapClientPoint = function (clientX, clientY) {
    const ScreenQuad = window.Baguette._ScreenQuad;
    const outside = { x: 0, y: 0, xNorm: 0, yNorm: 0, inside: false };
    if (!this.screenQuad || !this.canvas || !this.canvas.width || !this.canvas.height) {
      return outside;
    }
    const rect = ScreenQuad.contentRect(this.canvas);
    if (!rect.width || !rect.height) return outside;
    const contentU = (clientX - rect.left) / rect.width;
    const contentV = (clientY - rect.top) / rect.height;
    const solved = this.screenQuad.locate(contentU, contentV);
    const xNorm = Math.max(0, Math.min(1, solved.u));
    const yNorm = Math.max(0, Math.min(1, solved.v));
    const { width, height } = this.deviceSize;
    return { x: xNorm * width, y: yNorm * height, xNorm, yNorm, inside: solved.inside };
  };

  Sim3DPanel.prototype.sendCamera = function () {
    if (this.cameraFrame) return;
    this.cameraFrame = requestAnimationFrame(() => {
      this.cameraFrame = 0;
      this.send({
        type: 'set_3d_camera',
        rotation: this.rotation,
        zoom: this.zoom,
      });
    });
  };

  Sim3DPanel.prototype.syncCameraControls = function () {
    ['x', 'y', 'z'].forEach((axis) => {
      const value = Math.round(this.rotation[axis]);
      const range = this.host && this.host.querySelector('[data-axis="' + axis + '"]');
      const output = this.host && this.host.querySelector('[data-value="' + axis + '"]');
      if (range) range.value = String(value);
      if (output) output.textContent = value + '°';
    });
  };

  Sim3DPanel.prototype.resetCamera = function () {
    this.rotation = { x: 0, y: 0, z: 0 };
    this.zoom = 1;
    this.syncCameraControls();
    this.sendCamera();
  };

  Sim3DPanel.prototype.zoomCamera = function (event) {
    if (this.mode !== 'pose') return;
    event.preventDefault();
    this.zoom = Math.max(0.5, Math.min(3,
        this.zoom * Math.exp(-event.deltaY * 0.0015)));
    this.sendCamera();
  };

  /**
   * The dimensions of the live 3D frame — what a ratio size (`square`,
   * `16:9`) resolves against, since a 3D render has no other intrinsic
   * size in the browser. Falls back to the size the stream was asked for
   * before the first frame lands.
   */
  Sim3DPanel.prototype.streamSize = function () {
    if (this.canvas && this.canvas.width && this.canvas.height) {
      return { width: this.canvas.width, height: this.canvas.height };
    }
    return this.stage ? this.outputSize() : null;
  };

  /**
   * Save the current pose as a PNG.
   *
   * The canvas holds a *video-decoded* frame at the live stream's clamped
   * resolution — fine to look at, lossy to ship. So we ask the server to
   * re-render the very same pose once, off the stream, at the size the
   * user picked; that comes back as a clean full-resolution PNG. The
   * canvas is still the safety net: if the route is missing or the render
   * fails, the user gets the live frame rather than no file at all.
   */
  Sim3DPanel.prototype.download = async function () {
    if (!this.canvas || !this.canvas.hasAttribute('data-painted')) return;
    // One click, one render. Each save costs the server a fresh screen
    // capture plus a RealityKit render, so a double-click must not queue
    // two of them (and hand the user two files).
    if (this.saving) return;
    this.saving = true;
    this.setSaving(true);
    const settings = this.captureSettings;
    try {
      if (Math.abs(this.zoom - 1) > 0.01) {
        // `DeviceRenderOptions` has no zoom field — the one-shot render
        // always frames at the model's default camera distance. Say so
        // rather than quietly handing back a differently-framed PNG.
        console.warn(
            '[3d] saved render ignores the live zoom (' +
            this.zoom.toFixed(2) + '×) — it frames at 1×'
        );
      }
      const body = Sim3DPanel.renderBody({
        rotation: this.rotation,
        variants: this.variants,
        screenGlass: this.screenGlass,
        background: this.background,
        settings: settings,
        streamSize: this.streamSize(),
      });
      const response = await fetch(
          (window.BaguetteTarget
              ? window.BaguetteTarget.path(this.udid, '/render-3d.png')
              : '/simulators/' + encodeURIComponent(this.udid) + '/render-3d.png'),
          {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
          }
      );
      if (!response.ok) {
        throw new Error('render-3d.png returned HTTP ' + response.status);
      }
      const blob = await response.blob();
      // Name the file after what actually came back, not what we asked
      // for — `native` doesn't send a size at all, and the server is the
      // one that knows the screen's true pixel dimensions.
      const size = Sim3DPanel.pngSize(new Uint8Array(await blob.arrayBuffer()));
      const name = settings && size
        ? this.modelId() + '-3d-' + fileSafe(settings.slug(size.width, size.height))
        : this.modelId() + '-3d';
      const url = URL.createObjectURL(blob);
      saveLink(url, name + '.png');
      // Revoke on the next turn — Safari needs the URL to still resolve
      // when it processes the synthetic click.
      setTimeout(() => URL.revokeObjectURL(url), 0);
    } catch (error) {
      console.warn(
          '[3d] lossless render failed, saving the live frame instead', error
      );
      this.downloadLiveFrame();
    } finally {
      this.saving = false;
      this.setSaving(false);
    }
  };

  /** Busy state on the Save Frame button while a render is in flight. */
  Sim3DPanel.prototype.setSaving = function (busy) {
    const button = this.host && this.host.querySelector('[data-role="download"]');
    if (!button) return;
    button.disabled = !!busy;
    button.textContent = busy ? 'Rendering…' : 'Save Frame';
  };

  /** Last resort: the lossy on-screen frame, named for what it is. */
  Sim3DPanel.prototype.downloadLiveFrame = function () {
    if (!this.canvas || !this.canvas.hasAttribute('data-painted')) return;
    saveLink(this.canvas.toDataURL('image/png'), this.modelId() + '-live-3d.png');
  };

  Sim3DPanel.prototype.modelId = function () {
    return (this.model && this.model.id) || 'device';
  };

  /**
   * The `DeviceRenderOptions` JSON for `POST /simulators/:udid/render-3d.png`,
   * built from the current pose plus the shared CaptureSettings.
   *
   * Pure and static so the arithmetic is testable without a canvas: given
   * a pose and a size choice, exactly one body comes out.
   *
   * Two things worth knowing about the mapping:
   *  • `size` is OMITTED for `native` — the server then renders at the
   *    simulator screen's own pixel size, which is larger (and truer)
   *    than anything the browser could name.
   *  • the requested size is NOT run through `outputSize()`'s 480–1600
   *    clamp. That clamp exists to keep the live video stream cheap; a
   *    one-shot App Store render is meant to be 1290 × 2796.
   *
   * @param {object} o
   * @param {{x:number,y:number,z:number}} [o.rotation]
   * @param {object} [o.variants]
   * @param {boolean} [o.screenGlass]
   * @param {object} [o.settings]    CaptureSettings; absent → live framing
   * @param {{width:number,height:number}} [o.streamSize] ratio sizes resolve
   *   against this
   * @param {string} [o.background]  fallback canvas colour when there are
   *   no settings — keeps the saved PNG looking like the live view
   */
  Sim3DPanel.renderBody = function (o) {
    const options = o || {};
    const rotation = options.rotation || {};
    const body = {
      rotation: {
        x: Number(rotation.x) || 0,
        y: Number(rotation.y) || 0,
        z: Number(rotation.z) || 0,
      },
      // Copied, not aliased: the panel keeps mutating `this.variants` as
      // the user clicks finishes, and an in-flight request must not move.
      variants: Object.assign({}, options.variants),
      screenGlass: !!options.screenGlass,
      // Always `cover`, never the CaptureSettings fit. On this route `fit`
      // is NOT canvas placement — the server hands it to the screen
      // texture's UV placement on the device mesh, i.e. how the captured
      // frame sits on the display. The live stream asks for `cover`, so
      // asking for anything else here would save a render that doesn't
      // match what the user was looking at. Canvas placement on a 3D
      // render is the camera's job, and there is no fit for it.
      fit: 'cover',
    };
    const settings = options.settings;
    if (!settings) {
      body.background = options.background || 'transparent';
      return body;
    }
    // `effectiveBackground` reports `transparent` at native size, so a
    // transparent 3D render never gains an unwanted white mat.
    body.background = settings.effectiveBackground;
    if (!settings.size.isNative) {
      const stream = options.streamSize || {};
      const size = settings.size.resolve(stream.width, stream.height);
      // A ratio with no source to resolve against yields 0 × 0; leaving
      // `size` off falls back to the server's native render instead of
      // asking for an empty image.
      if (size.width > 0 && size.height > 0) body.size = size;
    }
    return body;
  };

  /**
   * Width/height straight out of a PNG's IHDR chunk — the 8-byte
   * signature, then a chunk header, then two big-endian uint32s at byte
   * 16. Cheaper and synchronous compared with decoding the blob into an
   * `Image` just to read `naturalWidth` for a filename.
   *
   * @param {Uint8Array} bytes
   * @returns {{width:number,height:number}|null}
   */
  Sim3DPanel.pngSize = function (bytes) {
    if (!bytes || bytes.length < 24) return null;
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    for (let i = 0; i < signature.length; i += 1) {
      if (bytes[i] !== signature[i]) return null;
    }
    const read = (at) => (
      (bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3]) >>> 0
    );
    const width = read(16);
    const height = read(20);
    return width > 0 && height > 0 ? { width, height } : null;
  };

  /**
   * A CaptureSettings slug can carry a ratio spec (`16:9-1600x900`), and
   * a colon is an illegal filename character on Windows and shows up as
   * `/` in Finder — fold anything outside the safe set to a dash.
   */
  function fileSafe(name) {
    return String(name).replace(/[^a-z0-9._-]+/gi, '-');
  }

  function saveLink(href, name) {
    const link = document.createElement('a');
    link.href = href;
    link.download = name;
    link.click();
  }

  function rangeRow(axis, label, min, max, value) {
    return '<div class="r3d-range-row"><span>' + label + '</span>' +
        '<input type="range" min="' + min + '" max="' + max + '" value="' +
        value + '" data-axis="' + axis + '">' +
        '<output data-value="' + axis + '">' + value + '°</output></div>';
  }
  function escapeHTML(value) {
    const div = document.createElement('div');
    div.textContent = String(value || '');
    return div.innerHTML;
  }
  function escapeAttr(value) {
    return escapeHTML(value).replace(/"/g, '&quot;');
  }
  function cssEscape(value) {
    return window.CSS && CSS.escape ? CSS.escape(value) : value.replace(/"/g, '\\"');
  }

  window.Sim3DPanel = Sim3DPanel;
})();
