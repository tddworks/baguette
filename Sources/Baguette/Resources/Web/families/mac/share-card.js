// Sharing this Mac, from the devices page: a card that asks the Mac for a
// display the shape of this screen — with the room and use chosen — and opens
// it. The same card is /mac/share's whole page, kept for compatibility.
// `browser` is what this touches of the page:
//
//   { width, height, devicePixelRatio, userAgent, search, fetch }
import { MacShare } from './share.js';

/** Ask the Mac for the display; where its page opens. Throws why it made none. */
export async function startShare({ room, use }, browser) {
  const body = MacShare.request({
    viewport: { width: browser.width, height: browser.height },
    pixelRatio: browser.devicePixelRatio,
    userAgent: browser.userAgent,
    room,
    use,
  });
  const response = await browser.fetch('/mac/shares', { method: 'POST', body: JSON.stringify(body) });
  const answer = await response.json().catch(() => ({}));
  if (!response.ok || !answer.id) throw new Error(answer.error || 'The Mac didn’t make the display');
  return MacShare.pageAddress(answer.id, body.room, new URLSearchParams(browser.search).get('codec'));
}

/** Whether this server shares the Mac (`serve --share-mac`): it has the share page. */
export async function sharingOn(browser) {
  try { return (await browser.fetch('/mac/share', { method: 'GET' })).ok; } catch { return false; }
}

/** The devices list — not a device's own page, which never shows the card. */
export function isDevicesList(path) {
  return path === '/simulators' || path === '/simulators/' || path === '/devices' || path === '/devices/';
}

const STYLE = `
  .mac-share { --ms-card: #fff; --ms-ink: #1f2937; --ms-muted: #64748b; --ms-line: #e2e8f0;
               --ms-accent: #2563eb; --ms-accent-soft: #eff6ff;
               background: var(--ms-card); color: var(--ms-ink); border: 1px solid var(--ms-line);
               border-radius: 16px; padding: 22px; display: flex; flex-direction: column; gap: 18px;
               font: 15px/1.45 -apple-system, BlinkMacSystemFont, Inter, sans-serif; box-sizing: border-box; }
  @media (prefers-color-scheme: dark) {
    .mac-share { --ms-card: #181b22; --ms-ink: #e5e7eb; --ms-muted: #94a3b8; --ms-line: #2a2f3a;
                 --ms-accent: #60a5fa; --ms-accent-soft: #1e293b; }
  }
  .mac-share * { box-sizing: border-box; }
  .mac-share h2 { margin: 0; font-size: 20px; }
  .mac-share p { margin: 0; color: var(--ms-muted); }
  .mac-share fieldset { border: 0; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .mac-share legend { font-weight: 700; margin-bottom: 8px; }
  .mac-share label { display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px;
                     border: 1px solid var(--ms-line); border-radius: 10px; cursor: pointer; }
  .mac-share label:has(input:checked) { border-color: var(--ms-accent); background: var(--ms-accent-soft); }
  .mac-share label small { display: block; color: var(--ms-muted); }
  .mac-share input[type=radio] { margin-top: 3px; accent-color: var(--ms-accent); }
  .mac-share button { width: 100%; height: 46px; border: 0; border-radius: 12px; background: var(--ms-accent);
                      color: #fff; font: inherit; font-weight: 700; cursor: pointer; margin-top: 18px; }
  .mac-share button:disabled { opacity: .6; cursor: default; }
  .mac-share .mac-share-error { color: #dc2626; min-height: 1em; }
`;

const FORM = `
  <h2>Share this Mac here</h2>
  <p>This Mac makes a display the shape of this screen and shows it here, to watch and control. It goes away when you leave.</p>
  <form>
    <fieldset>
      <legend>Room</legend>
      <label><input type="radio" name="room" value="largerText"><span>Larger text<small>The Mac's text is the size of this device's</small></span></label>
      <label><input type="radio" name="room" value="standard" checked><span>Standard<small>Sharp on this screen: its own pixels</small></span></label>
      <label><input type="radio" name="room" value="moreSpace"><span>More space<small>The most room, the smallest text</small></span></label>
    </fieldset>
    <fieldset style="margin-top:16px">
      <legend>Use as</legend>
      <label><input type="radio" name="use" value="main" checked><span>Main display<small>The menu bar, the Dock and new windows open here</small></span></label>
      <label><input type="radio" name="use" value="extra"><span>Extended display<small>One more display beside the Mac's own</small></span></label>
    </fieldset>
    <button type="submit">Share</button>
  </form>
  <p class="mac-share-error" role="alert"></p>
`;

/** The card in `host`; sharing opens the shared display's page (`open`). */
export function mountShareCard(host, browser, open) {
  if (!document.getElementById('macShareStyle')) {
    const style = document.createElement('style');
    style.id = 'macShareStyle';
    style.textContent = STYLE;
    document.head.appendChild(style);
  }
  host.classList.add('mac-share');
  host.innerHTML = FORM;
  const form = host.querySelector('form');
  const error = host.querySelector('.mac-share-error');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const button = form.querySelector('button');
    button.disabled = true;
    error.textContent = '';
    try {
      open(await startShare({ room: form.room.value, use: form.use.value }, browser));
    } catch (failure) {
      error.textContent = failure.message;
      button.disabled = false;
    }
  });
}

/** This page, as the card sees it. */
export function pageBrowser() {
  return {
    get width() { return window.innerWidth; },
    get height() { return window.innerHeight; },
    get devicePixelRatio() { return window.devicePixelRatio; },
    userAgent: navigator.userAgent,
    search: location.search,
    fetch: (url, init) => fetch(url, init),
  };
}
