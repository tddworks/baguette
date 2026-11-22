// sim-notify.js — remote-notification card for the focus page.
//
// Hangs `window.NotifyPanel` on the global so page/device-page.js can surface a
// floating glass card that delivers a remote notification to an app, as if
// APNs had sent it.
//
// The panel is a dumb sender: "Send" posts the payload text verbatim to
// `POST /devices/<udid>/notify?bundleId=<id>` and shows what comes back.
// The Swift side owns every rule — what a valid payload is, which app it's
// addressed to, and the `expectation` line (delivered ≠ a banner showed),
// which the card repeats word for word. The last app and payload are kept
// in localStorage so a repeated manual check is one click. See
// `docs/features/notifications/README.md`.

(function () {
  'use strict';

  const STORE = 'baguette.notify';
  const EXAMPLE = JSON.stringify({
    aps: {
      alert: { title: 'Order update', body: 'Tap to view your order' },
      sound: 'default',
    },
    deep_link: 'example://orders/123',
  }, null, 2);

  function remembered() {
    try { return JSON.parse(localStorage.getItem(STORE)) || {}; } catch (_) { return {}; }
  }
  function remember(state) {
    try { localStorage.setItem(STORE, JSON.stringify(state)); } catch (_) { /* private window */ }
  }

  class NotifyPanel {
    constructor() {
      this.host = null;
      this.udid = null;
      const saved = remembered();
      this.state = { app: saved.app || '', payload: saved.payload || EXAMPLE };
    }

    /** @param {HTMLElement} host @param {string} udid */
    attach(host, udid) {
      if (!host || !udid) return;
      this.host = host;
      this.udid = udid;
      this._build();
    }

    detach() {
      if (this.host) { this.host.innerHTML = ''; this.host = null; }
    }

    _build() {
      this.host.innerHTML =
        '<div class="nt-section">' +
          '<label class="nt-label" for="ntApp">App</label>' +
          `<input id="ntApp" class="nt-field" data-k="app" type="text" spellcheck="false"
             placeholder="com.example.app" value="${escapeAttr(this.state.app)}"
             aria-label="Bundle identifier of the app to notify">` +
        '</div>' +
        '<div class="nt-section">' +
          '<label class="nt-label" for="ntPayload">Payload</label>' +
          `<textarea id="ntPayload" class="nt-field nt-payload" data-k="payload" rows="10"
             spellcheck="false" aria-label="Notification payload (JSON)">${escapeAttr(this.state.payload)}</textarea>` +
        '</div>' +
        '<div class="nt-section nt-footer">' +
          '<button class="nt-example" data-act="example">Example</button>' +
          '<button class="nt-send" data-act="send">Send</button>' +
        '</div>' +
        '<p class="nt-result" role="status" aria-live="polite"></p>';

      this.host.querySelectorAll('[data-k]').forEach((el) => {
        el.addEventListener('input', () => {
          this.state[el.getAttribute('data-k')] = el.value;
          remember(this.state);
        });
      });
      this.host.querySelector('[data-act="example"]').onclick = () => {
        this.state.payload = EXAMPLE;
        this.host.querySelector('[data-k="payload"]').value = EXAMPLE;
        remember(this.state);
      };
      this.host.querySelector('[data-act="send"]').onclick = () => this.send();
    }

    async send() {
      if (!this.udid || !this.host) return;
      const app = this.state.app.trim();
      const url = `/devices/${encodeURIComponent(this.udid)}/notify`
        + (app ? `?bundleId=${encodeURIComponent(app)}` : '');
      this._show('Sending…', '');
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: this.state.payload,
        });
        const data = await res.json().catch(() => ({}));
        if (res.ok && data.ok) this._show(data.expectation || 'Delivered.', 'ok');
        else this._show(data.error || `notify failed (${res.status})`, 'error');
      } catch (e) {
        this._show(`notify failed: ${e.message || e}`, 'error');
      }
    }

    _show(text, tone) {
      const out = this.host && this.host.querySelector('.nt-result');
      if (!out) return;
      out.textContent = text;
      out.className = 'nt-result' + (tone ? ` ${tone}` : '');
    }
  }

  function escapeAttr(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  window.NotifyPanel = NotifyPanel;
})();
