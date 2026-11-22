// A Mac display's frame picker: it shows with no frame until one is picked;
// a button beside its badge offers the Mac frames it fits — asked of the
// server by the display's own size — and no frame. A pick is remembered per
// display, as a phone's borrowed chrome is, and the page reloads into it.

const KEY = (id) => 'baguette.twin.chrome.' + id;

/** The frames that fit display `id`, by its frameless definition's screen; none when it can't say. */
export async function framesThatFit(id, devices) {
  try {
    const own = await devices.definition(id);
    const rect = own && own.screen && own.screen.rect;
    return rect ? await devices.framesFitting(rect.width, rect.height) : [];
  } catch { return []; }
}

/** Remember `pick` for display `id` (nil: no frame). */
export function rememberFrame(storage, id, pick) {
  try {
    if (pick) storage.setItem(KEY(id), pick);
    else storage.removeItem(KEY(id));
  } catch { /* nothing remembered: the page keeps its look */ }
}

/** The picker for display `id`: `mount(badge)` puts its button beside the badge. */
export function macFramePicker(id, { devices, storage, reload }) {
  async function show(anchor) {
    const open = document.getElementById('nativeMacFramePicker');
    if (open) { open.remove(); return; }
    let picked = null;
    try { picked = storage.getItem(KEY(id)); } catch { /* nothing picked */ }
    const choices = window.Baguette._MacFrameChoices.of(await framesThatFit(id, devices), picked);
    const pop = document.createElement('div');
    pop.id = 'nativeMacFramePicker';
    pop.style.cssText =
        'position:absolute;z-index:70;display:flex;flex-direction:column;gap:4px;min-width:220px;' +
        'padding:8px;background:#fff;border:1px solid #e2e8f0;border-radius:10px;' +
        'box-shadow:0 12px 32px rgba(15,23,42,.14);font:400 12.5px/1.4 -apple-system,Inter,sans-serif';
    choices.forEach((choice) => {
      const item = document.createElement('button');
      item.type = 'button';
      item.textContent = (choice.chosen ? '✓ ' : '') + choice.label;
      item.style.cssText =
          'text-align:left;padding:6px 10px;border:0;border-radius:7px;cursor:pointer;' +
          'background:' + (choice.chosen ? '#eff6ff' : 'transparent') + ';color:#1f2937;font:inherit';
      // The pick rides the reload too, in case the browser wouldn't store it.
      item.addEventListener('click', () => { rememberFrame(storage, id, choice.pick); reload({ chrome: choice.pick || null }); });
      pop.appendChild(item);
    });
    if (choices.length === 1) {
      const hint = document.createElement('span');
      hint.style.cssText = 'padding:4px 10px;color:#94a3b8;font-size:11.5px';
      hint.textContent = 'No Mac frame fits this display, or none is installed — see docs/features/mac-screen.';
      pop.appendChild(hint);
    }
    const box = anchor.getBoundingClientRect();
    pop.style.left = (box.left + window.scrollX) + 'px';
    pop.style.top = (box.bottom + window.scrollY + 6) + 'px';
    document.body.appendChild(pop);
  }

  return {
    mount(badge) {
      if (!badge || document.getElementById('nativeMacFrameButton')) return;
      const button = document.createElement('button');
      button.id = 'nativeMacFrameButton';
      button.type = 'button';
      button.textContent = 'Frame';
      button.title = 'Show this display in a Mac frame, or none';
      button.style.cssText =
          'margin-left:6px;padding:2px 10px;border:1px solid #dbeafe;border-radius:99px;' +
          'background:#eff6ff;color:#2563eb;font-size:10.5px;font-weight:700;cursor:pointer';
      // The badge sits inside the header's link back to the device list: the
      // button goes after that link, and its click goes no further, so
      // opening the picker never leaves the page.
      button.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        void show(button);
      });
      (badge.closest('a') || badge).insertAdjacentElement('afterend', button);
    },
  };
}
