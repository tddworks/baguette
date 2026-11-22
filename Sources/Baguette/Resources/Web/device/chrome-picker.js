// The chrome picker: a device with no bezel of its own (a phone on the
// cable, an Android device) borrows a phone's or tablet's chrome. Real
// hardware ships no bezel bundle, and baguette never guesses one; the pick is
// remembered per device and the page reloads into it.

const EVERGREEN = ['iPhone 17 Pro', 'iPhone 17 Pro Max', 'iPhone 17', 'iPhone Air'];

/** The chromes to offer: the current iPhones, then each installed phone or tablet once. */
export function chromeChoices(simulators) {
  const names = simulators ? (simulators.running || []).concat(simulators.available || [])
    .map((d) => d.name).filter(Boolean) : [];
  // Phones and tablets only: a watch or TV bezel can't frame a phone's screen.
  return [...new Set(EVERGREEN.concat(names))].filter((n) => /^iP(hone|ad)\b/.test(n));
}

/** The picker for device `id`: `show(host)` covers the view with the choices. */
export function chromePicker(id, { wire, storage, reload }) {
  return {
    async show(host) {
      let simulators = null;
      try { simulators = await wire.simulators(); } catch { /* the current iPhones still show */ }
      const choices = chromeChoices(simulators);
      const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
      }[c]));
      const phoneGlyph =
          '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" ' +
          'stroke="currentColor" stroke-width="1.5" aria-hidden="true">' +
          '<rect x="4" y="1.5" width="8" height="13" rx="2"></rect>' +
          '<path d="M6.5 3 L9.5 3"></path></svg>';
      const card = document.createElement('div');
      card.id = 'nativeChromePicker';
      // Over the whole view: the device frame has no size until a bezel is
      // chosen, so a card inside it would be squeezed to a sliver.
      card.style.cssText =
          'position:fixed;inset:0;display:flex;align-items:center;overflow:auto;' +
          'justify-content:center;z-index:60;background:var(--bg,#f8fafc);' +
          'font:400 13px/1.45 -apple-system,BlinkMacSystemFont,Inter,sans-serif';
      card.innerHTML =
          '<div style="display:flex;flex-direction:column;gap:6px;width:420px;flex:none;' +
          'max-width:calc(100vw - 48px);padding:24px;background:#fff;' +
          'border:1px solid #e2e8f0;border-radius:14px;' +
          'box-shadow:0 12px 32px rgba(15,23,42,.10)">' +
          '<div style="display:flex;align-items:center;gap:8px">' +
          '<strong style="color:#1f2937;font-size:15px">Pick a frame for this device</strong>' +
          '<span style="height:18px;padding:0 8px;display:inline-flex;align-items:center;' +
          'border:1px solid #dbeafe;border-radius:99px;background:#eff6ff;color:#2563eb;' +
          'font-size:10.5px;font-weight:700;letter-spacing:.03em">DEVICE</span></div>' +
          '<span style="color:#94a3b8">Real hardware ships no bezel bundle, and ' +
          'baguette never guesses one — borrow a device chrome:</span>' +
          '<div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));' +
          'gap:8px;margin-top:10px">' +
          choices.map((n) =>
              '<button type="button" data-chrome-pick="' + esc(n) + '" ' +
              'style="display:flex;align-items:center;gap:8px;height:38px;' +
              'padding:0 12px;border:1px solid #e2e8f0;border-radius:9px;' +
              'background:#f8fafc;color:#475569;font:inherit;font-size:12.5px;' +
              'font-weight:700;cursor:pointer;text-align:left;' +
              'transition:border-color .12s,background .12s" ' +
              'onmouseover="this.style.borderColor=\'#93c5fd\';this.style.background=\'#eff6ff\'" ' +
              'onmouseout="this.style.borderColor=\'#e2e8f0\';this.style.background=\'#f8fafc\'">' +
              phoneGlyph + '<span style="overflow:hidden;text-overflow:ellipsis;' +
              'white-space:nowrap">' + esc(n) + '</span></button>').join('') +
          '</div>' +
          '<span style="margin-top:8px;color:#94a3b8;font-size:12px">The frame is ' +
          'cosmetic — the mirror inside it is your phone either way. Remembered ' +
          'for this device.</span></div>';
      host.style.position = host.style.position || 'relative';
      host.appendChild(card);
      card.querySelectorAll('[data-chrome-pick]').forEach((btn) => {
        btn.addEventListener('click', () => {
          try { storage.setItem('baguette.twin.chrome.' + id, btn.dataset.chromePick); } catch { /* not remembered */ }
          // The pick rides the reload too, in case the browser wouldn't store it.
          reload({ chrome: btn.dataset.chromePick });
        });
      });
    },
  };
}
