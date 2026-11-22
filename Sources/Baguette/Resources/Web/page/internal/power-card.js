// The power card: on the screen of a device that isn't running — booting
// it when its family can (its `power`), saying so as it comes up, and gone
// once a frame lands. Watches for a boot started elsewhere (`baguette boot`,
// Xcode, another tab). What it needs of the page is its port:
// { device, deviceName, sim, foldable, startMainView(), resetToPortrait() }.
// Out of page/device-page.js (design §4).

export function powerCard(page) {
  let powerCard = null;      // boot affordance shown on an unbooted device's screen
  let bootPollTimer = null;  // /simulators.json poll while a boot is in flight
  let firstFrameTimer = null; // fallback so the card can't outlive a live stream
  const BOOT_POLL_MS = 1000;
  const BOOT_TIMEOUT_MS = 180000;   // cold boots on a busy Mac are slow
  const FIRST_FRAME_TIMEOUT_MS = 15000;
  const IDLE_POLL_MS = 4000;        // watch for a boot we didn't start

  function isBooted(state) {
    return String(state || '') === 'Booted';
  }

  function showPowerCard(state) {
    hidePowerCard();

    // Normally the card goes on the device's own glass. With no
    // definition there's no bezel to sit inside, so it stands alone in
    // the empty device slot and gets its own device-ish silhouette.
    const glass = page.sim && page.sim.screenArea;
    const host = glass || document.getElementById('nativeDeviceFrame');
    if (!host) return;

    powerCard = document.createElement('div');
    powerCard.className = glass ? 'power-card' : 'power-card power-card--bare';
    // The SDK's PointerInterpreter is attached to the same screenArea.
    // Without this, clicking Boot also dispatches a tap gesture at the
    // button's coords into a simulator that can't receive it.
    ['pointerdown', 'pointerup', 'pointermove', 'mousedown', 'mouseup', 'click']
        .forEach((evt) => powerCard.addEventListener(evt, (e) => e.stopPropagation()));
    host.appendChild(powerCard);

    if (!state) {
      renderPowerCard('gone');
    } else if (String(state) === 'Booting') {
      // Someone else already started it — join the wait rather than
      // POSTing a second boot.
      renderPowerCard('booting');
      waitForBoot();
    } else {
      renderPowerCard('off');
    }
  }

  function hidePowerCard() {
    if (!powerCard && !bootPollTimer && !firstFrameTimer) return;
    if (bootPollTimer)   { clearTimeout(bootPollTimer);   bootPollTimer = null; }
    if (firstFrameTimer) { clearTimeout(firstFrameTimer); firstFrameTimer = null; }
    if (powerCard && powerCard.parentNode) powerCard.parentNode.removeChild(powerCard);
    powerCard = null;
    const view = document.getElementById('simNativeView');
    if (view) view.removeAttribute('data-power');
  }

  const POWER_GLYPH =
      '<path d="M12 3.5v7.5"/>' +
      '<path d="M6.9 6.9a7.5 7.5 0 1 0 10.2 0"/>';
  const SPIN_GLYPH =
      '<circle cx="12" cy="12" r="8.6" stroke-opacity="0.22"/>' +
      '<path d="M20.6 12A8.6 8.6 0 0 0 12 3.4"/>';

  // Renders one phase into the existing card. `detail` overrides the
  // subtitle — used to surface a boot failure verbatim instead of a
  // generic "try again".
  function renderPowerCard(phase, detail) {
    if (!powerCard) return;
    // Whatever poll belonged to the previous phase is done with.
    if (bootPollTimer) { clearTimeout(bootPollTimer); bootPollTimer = null; }
    powerCard.setAttribute('data-phase', phase);
    // Presence of `data-power` on the root is what dims the toolbar;
    // the value carries the phase for anyone inspecting the DOM.
    const view = document.getElementById('simNativeView');
    if (view) view.setAttribute('data-power', phase);

    const copy = {
      // Only a device whose family boots it (its `power`) offers to.
      off:      { title: page.device.power ? 'Not booted' : 'Not ready', sub: page.deviceName || 'This device',
                  btn: page.device.power ? 'Boot' : null },
      booting:  { title: 'Booting…',    sub: 'Waiting for CoreSimulator',    btn: null },
      starting: { title: 'Starting…',   sub: 'Waiting for the first frame',  btn: null },
      gone:     { title: 'Unavailable', sub: 'This simulator is no longer in the device set.', btn: null },
    }[phase] || {};

    const glyph = (phase === 'booting' || phase === 'starting') ? SPIN_GLYPH : POWER_GLYPH;
    powerCard.innerHTML =
        '<svg class="power-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="1.7" stroke-linecap="round" width="34" height="34" aria-hidden="true">' +
        glyph + '</svg>' +
        '<div class="power-title"></div>' +
        '<div class="power-sub"></div>' +
        (copy.btn ? '<button class="power-btn" type="button"></button>' : '');

    powerCard.querySelector('.power-title').textContent = copy.title || '';
    const sub = powerCard.querySelector('.power-sub');
    sub.textContent = detail || copy.sub || '';
    if (detail) sub.setAttribute('data-error', 'true');

    const btn = powerCard.querySelector('.power-btn');
    if (btn) {
      btn.textContent = copy.btn;
      btn.addEventListener('click', requestBoot);
    }

    const status = document.getElementById('nativeStatus');
    if (status) status.textContent = phase === 'gone' ? 'unavailable' : 'not booted';

    if (phase === 'off') watchForExternalBoot();
  }

  // While the Boot button is up, keep an eye on the device — it can
  // come up from anywhere: `baguette boot`, another tab, Xcode,
  // `simctl`. Without this the card would sit on "Not booted" over an
  // already-running guest until the user clicked a button they no
  // longer needed (and CoreSimulator rejects a boot in that state, so
  // the click would report a failure that isn't one).
  function watchForExternalBoot() {
    bootPollTimer = setTimeout(async () => {
      bootPollTimer = null;
      if (!powerCard || powerCard.getAttribute('data-phase') !== 'off') return;
      const meta = await page.device.describe();
      if (!powerCard) return;
      if (isBooted(meta.state)) onBooted();
      else watchForExternalBoot();
    }, IDLE_POLL_MS);
  }

  // POST /devices/<udid>/boot, then poll until CoreSimulator agrees.
  // The route is synchronous on the server side (it calls
  // `bootWithOptions:error:`), but "returned" only means the boot was
  // accepted — the guest keeps coming up afterwards, which is what the
  // poll is for.
  async function requestBoot() {
    renderPowerCard('booting');
    try {
      const booted = await page.device.power.boot();
      if (!booted.ok) {
        // CoreSimulator refuses a boot when the device is already
        // booted. If that's why this failed, the user got what they
        // wanted — go live instead of reporting an error.
        const meta = await page.device.describe();
        if (isBooted(meta.state)) { onBooted(); return; }
        renderPowerCard('off', booted.error);
        return;
      }
    } catch (e) {
      renderPowerCard('off', 'boot request failed — is the server still running?');
      return;
    }
    waitForBoot();
  }

  function waitForBoot(deadline) {
    const until = deadline || (Date.now() + BOOT_TIMEOUT_MS);
    bootPollTimer = setTimeout(async () => {
      if (!powerCard) return;            // card dismissed underneath us
      const meta = await page.device.describe();
      if (isBooted(meta.state)) {
        onBooted();
        return;
      }
      if (Date.now() >= until) {
        renderPowerCard('off',
            'still not booted after ' + Math.round(BOOT_TIMEOUT_MS / 60000) + ' min');
        return;
      }
      waitForBoot(until);
    }, BOOT_POLL_MS);
  }

  // CoreSimulator flipped to Booted. That's earlier than SpringBoard
  // being on screen, so keep the card up (as "Starting…") until a
  // frame actually lands — with a fallback, because the stream only
  // emits when SimulatorKit composites and a device sitting on a
  // static screen may not composite anything for a while.
  function onBooted() {
    renderPowerCard('starting');
    page.startMainView();
    if (!page.foldable) page.resetToPortrait();
    firstFrameTimer = setTimeout(hidePowerCard, FIRST_FRAME_TIMEOUT_MS);
  }

  // The live view of a booted guest: the flat stream in the device's
  // chrome, or — on a foldable — the book, straight on.
  return { isBooted, showPowerCard, hidePowerCard };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._PowerCard = { powerCard };
}
