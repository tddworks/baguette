// The live view: the device's screen as it streams — the session (a
// stream socket or WebRTC) in the format this browser picked and can
// decode, its text and first paint, and 3D, the other main-view mode that
// replaces it. Owns the session and the 3D panel; the page reads them
// through it. What it needs of the page is its port: { udid, device, sim,
// foldable, axInspector, pluginPanels, companionsUI, capture(), power(),
// rotation(), themeUI(), mountAxInspector(), mountPlugins() }.
// Out of page/device-page.js (design §4).

import { Sim3DPanel } from './device-3d.js';
import { StreamSession } from '../../stream/stream-session.js';
import { WhepSession } from '../../stream/whep-session.js';
import { StreamFormat } from '../../stream/stream-format.js';
import { StreamCodec } from '../../stream/stream-codec.js';
import { FrameDecoder } from '../../stream/frame-decoder.js';
import { MacShare } from '../../families/mac/share.js';

export function liveView(page) {
  let session = null;
  let render3DPanel = null;  // Sim3DPanel — live SceneKit stream + inspector
  let lastPaintedSize = { w: 0, h: 0 };
  function routeStreamText(env) {
    if (env && env.type === 'hinge') return true;   // the 3D scene follows the hinge
    if (page.axInspector && page.axInspector.handleEnvelope(env)) return true;
    if (env && env.type === 'paste_result') {
      if (!env.ok) console.warn('[native] paste failed:', env.error || 'unknown');
      return true;
    }
    if (env && env.type === 'copy_result') {
      console.log(env.ok
        ? '[native] copied sim pasteboard to host clipboard'
        : '[native] copy failed: ' + (env.error || 'unknown'));
      return true;
    }
    return false;
  }

  function sessionCallbacks(onFirstPaint) {
    let painted = false;
    return {
      onSize: (w, h) => {
        lastPaintedSize = { w, h };
        // First frame after a boot — the guest is genuinely up, so
        // drop the power card and hand the screen back to the stream.
        page.power().hidePowerCard();
        if (!painted) { painted = true; if (onFirstPaint) onFirstPaint(); }
      },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
      onText: routeStreamText,
    };
  }

  // Whether this browser's WebCodecs decoder plays HEVC, learned once (null
  // until known). A WebSocket stream waits the few milliseconds for it rather
  // than starting in H.264 and restarting: a phone on a cable sends no picture
  // to a live screen reopened that fast.
  let decodesHEVC = null;
  const hevcKnown = (typeof VideoDecoder !== 'undefined' && VideoDecoder.isConfigSupported
    ? VideoDecoder.isConfigSupported({ codec: 'hvc1.1.6.L93.B0', hardwareAcceleration: 'prefer-hardware' })
      .then((answer) => !!(answer && answer.supported), () => false)
    : Promise.resolve(false))
    .then((plays) => { decodesHEVC = plays; });
  let startsAsked = 0;

  function startSession(format) {
    // The newest ask wins: a start still waiting on the HEVC answer is dropped.
    const ask = ++startsAsked;
    if (format === 'avcc' && decodesHEVC === null) {
      hevcKnown.then(() => { if (ask === startsAsked) startSession(format); });
      return;
    }
    // A recording samples the canvas this session paints into; a
    // restart (format swap, 3D close, device re-open) leaves it blank
    // for however long the new socket takes to land its first frame.
    if (session) page.capture().cancelRecording('stream restarted');
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    // WebRTC is the phone plane only; a refused offer falls back to the
    // best socket format, as an undecodable one does below.
    const Session = format === 'webrtc' ? WhepSession : StreamSession;
    session = new Session(Object.assign({
      udid: page.udid, format, version: 'v2',
      display: 'phone',
      canvas: page.sim.canvas,
      // `?congestion=remb|transport-cc|off` on the page picks how a WebRTC
      // viewer's bitrate follows the link (default: the server's choice).
      congestion: new URLSearchParams(location.search).get('congestion') || undefined,
      // The codec picker's choice; `?codec=h264|h265|auto` on the page overrides it.
      // The WebSocket stream asks for HEVC only when this browser's decoder plays it.
      codec: format === 'webrtc' ? currentCodec().asked
        : format === 'avcc' ? currentCodec().forSocket({ decodesHEVC }) : undefined,
      onCodec: format === 'mjpeg' ? undefined : (mimeType) => reflectCodec(StreamCodec.arrived(mimeType)),
      onError: format === 'webrtc' ? () => {
        // A shared Mac's tab keeps its own choice: the socket from now on.
        const MacShare = sharedMac();
        if (MacShare) {
          try { sessionStorage.setItem(SHARE_FORMAT_KEY, MacShare.afterRefusal); } catch { /* the socket this once */ }
        } else {
          localStorage.removeItem(FORMAT_KEY);
        }
        startSession(MacShare ? StreamFormat.pick(MacShare.afterRefusal, decodeCapabilities()).id : currentFormat());
      } : undefined,
    }, sessionCallbacks()));
    // `boot()` runs this before wiring the toolbar and unload handler,
    // so a throw here killed the whole page, not just the canvas (#71).
    try {
      session.start();
    } catch (err) {
      console.warn('[native] ' + format + ' stream failed to start:',
          (err && err.message) || err);
      try { session.stop(); } catch (_) { /* ignore */ }
      session = null;
      if (format !== 'mjpeg') {
        localStorage.removeItem(FORMAT_KEY);
        startSession('mjpeg');
      }
      return;
    }
    // Companion panes are the user's standing choice, not this
    // session's — but their sockets don't survive a phone-session
    // restart's teardown, so reopen whichever are showing.
    if (page.companionsUI) page.companionsUI.resume(socketFormat());
    reflectFormat(format);
    // Restore the cached orientation across format-swap remounts,
    // so reopening the session doesn't snap the device back to
    // portrait while the simulator is still landscape.
    if (page.rotation().current !== 'portrait') page.rotation().apply(page.rotation().current);
    page.mountAxInspector();
    // Once only — `startSession` re-runs on every format swap, and
    // re-mounting would append a second copy of every rail button.
    if (!page.pluginPanels) page.mountPlugins();
  }

  // Which pill is lit, and which isn't offerable at all.
  function reflectFormat(format) {
    const caps = decodeCapabilities();
    document.querySelectorAll('#nativeFormatPicker .fmt-btn').forEach((b) => {
      b.classList.toggle('active', b.dataset.v === format);
      const fmt = StreamFormat.named(b.dataset.v);
      const playable = !fmt || fmt.isPlayable(caps);
      if (b.dataset.titleDefault == null) {
        b.dataset.titleDefault = b.getAttribute('title') || '';
      }
      b.disabled = !playable;
      b.title = playable ? b.dataset.titleDefault : fmt.whyUnplayable;
    });
    const codecs = document.getElementById('nativeCodecPicker');
    if (codecs) codecs.hidden = format !== 'webrtc' && format !== 'avcc';
    reflectCodec(null);
  }

  // The codec WebRTC asks for, remembered by this browser; the page
  // address's `?codec=` overrides it.
  const CODEC_KEY = 'asc.simCodec';
  function currentCodec() {
    let stored = null;
    try { stored = localStorage.getItem(CODEC_KEY); } catch { /* none stored */ }
    return StreamCodec.pick(new URLSearchParams(location.search).get('codec'), stored);
  }

  /** Lights the chosen codec; once the stream has `arrived`, says when HEVC fell back to H.264. */
  function reflectCodec(arrived) {
    const chosen = currentCodec();
    const note = chosen.note(arrived);
    document.querySelectorAll('#nativeCodecPicker .fmt-btn').forEach((b) => {
      const codec = StreamCodec.named(b.dataset.v);
      const isChosen = b.dataset.v === chosen.id;
      b.classList.toggle('active', isChosen);
      b.toggleAttribute('data-fell-back', isChosen && !!note);
      b.title = isChosen && note ? note : codec.title;
    });
  }

  /** Ask for codec `next` from now on: remembered, and a WebRTC stream restarted in it. */
  function setCodec(next) {
    const wanted = StreamCodec.named(next);
    if (!wanted) return;
    try { localStorage.setItem(CODEC_KEY, wanted.id); } catch { /* this session only */ }
    if (new URLSearchParams(location.search).has('codec')) {
      // The address's `?codec=` would win; drop it so the choice holds.
      const url = new URL(location.href);
      url.searchParams.delete('codec');
      history.replaceState(null, '', url.href);
    }
    reflectCodec(null);
    const format = currentFormat();
    if (session && (format === 'webrtc' || format === 'avcc')) startSession(format);
  }

  // The format every surface in this page streams at — phone, CarPlay,
  // watch and the 3D panel alike. Companions used to be pinned to MJPEG
  // independently of the phone, which meant a session the user had set to
  // H.264 still carried uncapped full JPEGs on its companion sockets.
  //
  // `StreamFormat` filters the stored value against what this browser
  // can decode, so nothing unplayable reaches the socket.
  /// The format asked for: a shared Mac's tab picks its own, WebRTC until it
  /// does, leaving the saved choice for every other device alone.
  /// The format this browser picked for every device (a shared Mac's tab keeps its own).
  const FORMAT_KEY = 'asc.simFormat';
  const SHARE_FORMAT_KEY = 'asc.shareFormat';
  function sharedMac() {
    return page.device && page.device.share ? MacShare : null;
  }

  function storedFormat() {
    const MacShare = sharedMac();
    if (!MacShare) return localStorage.getItem(FORMAT_KEY);
    let picked = null;
    try { picked = sessionStorage.getItem(SHARE_FORMAT_KEY); } catch { /* none picked */ }
    return MacShare.format(picked);
  }

  function currentFormat() {
    return StreamFormat
        .pick(storedFormat(), decodeCapabilities()).id;
  }

  /** What a surface that only has a stream socket — CarPlay, the watch,
   *  the 3D panel — streams at: the page's format, or for WebRTC the best
   *  socket format. */
  function socketFormat() {
    return StreamFormat
        .pick(storedFormat(), decodeCapabilities())
        .forSockets(decodeCapabilities()).id;
  }

  /** What this browser can play, as `StreamFormat` wants to be told it. */
  function decodeCapabilities() {
    return {
      hardwareDecoder: FrameDecoder.isHardwareAvailable(),
      webrtc: typeof window.RTCPeerConnection === 'function',
    };
  }

  // Live 3D is a main-view mode, not a duplicate preview. Its WebSocket
  // replaces the 2D StreamSession while open and carries both MJPEG
  // frames and the same inbound input/control envelopes.
  function toggle3D(opts) {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('native3DHost');
    const stage = document.getElementById('native3DStage');
    const btn = document.getElementById('native3DToggle');
    const open = view && view.getAttribute('data-render3d') === 'open';
    if (!view || !host || !stage || !page.sim) return;
    const fixed = !!(opts && opts.fixed);
    // A foldable lives in 3D: the cube turns the book, or sets it back
    // straight, rather than leaving for the flat stream.
    if (open && page.foldable && render3DPanel && !fixed) {
      render3DPanel.setFixed(!render3DPanel.fixed);
      if (btn) btn.classList.toggle('active', !render3DPanel.fixed);
      const inspector = !render3DPanel.fixed && localStorage.getItem('asc.3dInspector') !== 'closed';
      if (inspector) view.setAttribute('data-render3d-inspector', 'open');
      else view.removeAttribute('data-render3d-inspector');
      const sheet = document.getElementById('native3DSheet');
      if (sheet) sheet.setAttribute('aria-hidden', inspector ? 'false' : 'true');
      return;
    }
    // The canvas being recorded is about to be swapped for the other
    // mode's, and the two are different surfaces at different sizes.
    page.capture().cancelRecording('switched between 2D and 3D');
    // `open` is the state we're LEAVING, so it doubles as "will be 2D".
    page.capture().reflect3DCaptureControls(open);
    if (open) {
      view.removeAttribute('data-render3d');
      view.removeAttribute('data-render3d-inspector');
      if (btn) btn.classList.remove('active');
      if (render3DPanel) render3DPanel.stop();
      startSession(currentFormat());
    } else {
      if (session) {
        session.stop();
        session = null;
      }
      view.setAttribute('data-render3d', 'open');
      const inspectorOpen = !fixed && localStorage.getItem('asc.3dInspector') !== 'closed';
      if (inspectorOpen) {
        view.setAttribute('data-render3d-inspector', 'open');
      }
      const sheet = document.getElementById('native3DSheet');
      if (sheet) sheet.setAttribute('aria-hidden', inspectorOpen ? 'false' : 'true');
      if (btn) btn.classList.toggle('active', !fixed);
      const status = document.getElementById('nativeStatus');
      if (status) status.textContent = '3D live';
      // Told BEFORE the stream starts: a picked size raises the
      // stream's pixel budget (Sim3DPanel.streamBudget), so setting it
      // afterwards would open at the ordinary budget and restart.
      if (render3DPanel && typeof render3DPanel.setCaptureSettings === 'function') {
        render3DPanel.setCaptureSettings(page.capture().captureSettings());
      }
      if (!render3DPanel && page.udid) {
        render3DPanel = new Sim3DPanel();
        render3DPanel.setCaptureSettings(page.capture().captureSettings());
        render3DPanel.attach(host, stage, page.udid, {
          deviceSize: { width: page.sim.screen.size.width, height: page.sim.screen.size.height },
          format: socketFormat(),
          background: page.themeUI().live3DBackground(),
          fixed,
          onFps: (fps) => {
            const status = document.getElementById('nativeStatus');
            if (status) status.textContent = fps + ' fps · 3D';
          },
        });
      } else if (render3DPanel) {
        render3DPanel.background = page.themeUI().live3DBackground();
        if (render3DPanel.fixed !== fixed) render3DPanel.setFixed(fixed, { silent: true });
        render3DPanel.start();
      }
    }
  }

  // The inspector is a tool surface, not the 3D session owner. Collapsing it
  // must leave the model, decoder, socket, pose, zoom, and variant untouched.
  function toggle3DInspector() {
    const view = document.getElementById('simNativeView');
    const sheet = document.getElementById('native3DSheet');
    if (!view || view.getAttribute('data-render3d') !== 'open') return;
    const open = view.getAttribute('data-render3d-inspector') === 'open';
    if (open) {
      view.removeAttribute('data-render3d-inspector');
      localStorage.setItem('asc.3dInspector', 'closed');
    } else {
      view.setAttribute('data-render3d-inspector', 'open');
      localStorage.setItem('asc.3dInspector', 'open');
    }
    if (sheet) sheet.setAttribute('aria-hidden', open ? 'true' : 'false');
  }

  /** Stream in the format `next` (the picker's choice), when this browser
   *  plays it: remembered — per tab on a shared Mac's page — and the session
   *  (or the 3D view) moved onto it. */
  function setFormat(next) {
      // Storing an undecodable format wedges the origin (#71). The
      // button is already disabled; this is the second lock.
      const wanted = StreamFormat.named(next);
      if (!wanted || !wanted.isPlayable(decodeCapabilities())) return;
      const current = currentFormat();
      const view = document.getElementById('simNativeView');
      if (current === wanted.id && (session ||
          (view && view.getAttribute('data-render3d') === 'open'))) return;
      if (sharedMac()) {
        try { sessionStorage.setItem(SHARE_FORMAT_KEY, wanted.id); } catch { /* the tab forgets */ }
      } else {
        localStorage.setItem(FORMAT_KEY, wanted.id);
      }
      reflectFormat(wanted.id);
      if (view && view.getAttribute('data-render3d') === 'open') {
        if (render3DPanel) render3DPanel.setFormat(wanted.forSockets(decodeCapabilities()).id);
      } else {
        startSession(wanted.id);
      }
  }

  return {
    /** The stream session showing the device now, or null. */
    get session() { return session; },
    /** The live 3D panel, while 3D has been opened. */
    get render3DPanel() { return render3DPanel; },
    FORMAT_KEY, SHARE_FORMAT_KEY, setFormat, setCodec, currentCodec, currentFormat, decodeCapabilities, reflectFormat, sharedMac, socketFormat, startSession, toggle3D, toggle3DInspector };
}

