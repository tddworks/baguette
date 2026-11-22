// page/internal/file-drop.js — drag-and-drop files onto the device.
//
// Exports `SimFileDrop` so page/device-page.js can make the focus view
// accept dropped files: an .ipa/.app installs an app, an image/video lands
// in Photos.
//
// This is a dumb sender. For each dropped file it POSTs the raw bytes to
// `POST /devices/<udid>/files?name=<filename>` and shows the result.
// All domain logic — which file is an app vs media, which simctl verb,
// the "no home on a simulator" rejection — lives on the Swift side
// (`Server.addFile`, `AppBundle`, `AppArchive`, `MediaItem`). See
// docs/features/file-upload/README.md.
//
// A folder-form `.app` bundle can't travel as one File, so it's walked
// via webkitGetAsEntry and packed into a *stored* (uncompressed) zip
// right here, then POSTed as `<Name>.app.zip` for the Swift side to
// extract and install. The zip is transport encoding, not domain logic
// — every entry is stamped with unix mode 0755 in its external
// attributes so the app's executable survives `ditto -x -k` extraction
// with the exec bit intact. Symlinks and empty directories don't
// survive the browser's file-system API; iOS-style shallow bundles
// don't carry either.
//
// The drop highlight traces the device *screen* — the bezel exposes a
// `screenArea` rect with the exact clip-radius (Bezel.mount), so the
// overlay mirrors its geometry and reads as a clean rounded rectangle on
// the phone rather than a boxy bounding box with the side buttons poking
// through.

function ensureStyles() {
  if (document.getElementById('simFileDropStyles')) return;
  const s = document.createElement('style');
  s.id = 'simFileDropStyles';
  s.textContent = `
    .sfd-overlay {
      position: absolute; z-index: 5; box-sizing: border-box;
      display: flex; align-items: center; justify-content: center;
      background: rgba(16,18,24,0.42); backdrop-filter: blur(1.5px);
      border: 2px dashed rgba(255,255,255,0.85);
      font: 600 13px/1.35 -apple-system, system-ui, sans-serif; color: #fff;
      text-align: center; pointer-events: none; padding: 14px;
      text-shadow: 0 1px 3px rgba(0,0,0,0.55);
    }
    .sfd-overlay .sfd-plus {
      display: inline-flex; align-items: center; justify-content: center;
      width: 30px; height: 30px; margin-bottom: 9px; border-radius: 50%;
      background: rgba(255,255,255,0.16); font-size: 20px; line-height: 1;
    }
    .sfd-overlay .sfd-col { display: flex; flex-direction: column; align-items: center; }
    .sfd-toasts {
      position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%);
      z-index: 9999; display: flex; flex-direction: column; gap: 8px;
      align-items: center; pointer-events: none;
    }
    .sfd-toast {
      font: 500 13px/1.35 -apple-system, system-ui, sans-serif; color: #fff;
      background: rgba(28,30,38,0.94); border: 1px solid rgba(255,255,255,0.12);
      border-radius: 11px; padding: 8px 13px; max-width: 360px;
      box-shadow: 0 6px 22px rgba(0,0,0,0.35); transition: opacity .3s;
    }
    .sfd-toast.sfd-ok   { border-color: rgba(80,200,120,0.55); }
    .sfd-toast.sfd-err  { border-color: rgba(235,110,110,0.6); }
    .sfd-toast.sfd-busy { border-color: rgba(120,160,235,0.55); }
  `;
  document.head.appendChild(s);
}

function hasFiles(e) {
  return !!e.dataTransfer &&
    Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') >= 0;
}

// ---- stored-zip packer -------------------------------------------------
// Just enough of the zip format to carry a directory tree: local file
// headers + central directory + EOCD, method 0 (stored), UTF-8 names.
// No zip64 — the server caps uploads at 1 GiB anyway.

const CRC_TABLE = (function () {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) {
    c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}

// files: [{path: 'MyApp.app/Info.plist', bytes: Uint8Array}] → zip Blob.
// Every entry carries unix mode 0755 in its external attributes
// (0100755 << 16) so the app's binaries stay executable after
// extraction — the browser can't tell which files had the exec bit,
// and a spare exec bit on a plist is harmless.
function buildStoredZip(files) {
  if (files.length > 0xFFFF) throw new Error('too many files to pack');
  const encoder = new TextEncoder();
  const now = new Date();
  const dosTime = ((now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1)) & 0xFFFF;
  const dosDate = (((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate()) & 0xFFFF;

  const parts = [];
  const central = [];
  let offset = 0;
  let cdSize = 0;
  for (const f of files) {
    const name = encoder.encode(f.path);
    const crc = crc32(f.bytes);
    if (f.bytes.length >= 0xFFFFFFFF) throw new Error(f.path + ' too large to pack');

    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034B50, true);       // local header signature
    local.setUint16(4, 20, true);               // version needed
    local.setUint16(6, 0x0800, true);           // flags: UTF-8 names
    local.setUint16(8, 0, true);                // method: stored
    local.setUint16(10, dosTime, true);
    local.setUint16(12, dosDate, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, f.bytes.length, true);  // compressed size
    local.setUint32(22, f.bytes.length, true);  // uncompressed size
    local.setUint16(26, name.length, true);
    local.setUint16(28, 0, true);               // extra length
    parts.push(local.buffer, name, f.bytes);

    const cd = new DataView(new ArrayBuffer(46));
    cd.setUint32(0, 0x02014B50, true);          // central dir signature
    cd.setUint16(4, 0x031E, true);              // made by: unix, spec 3.0
    cd.setUint16(6, 20, true);
    cd.setUint16(8, 0x0800, true);
    cd.setUint16(10, 0, true);
    cd.setUint16(12, dosTime, true);
    cd.setUint16(14, dosDate, true);
    cd.setUint32(16, crc, true);
    cd.setUint32(20, f.bytes.length, true);
    cd.setUint32(24, f.bytes.length, true);
    cd.setUint16(28, name.length, true);
    cd.setUint16(30, 0, true);                  // extra length
    cd.setUint16(32, 0, true);                  // comment length
    cd.setUint16(34, 0, true);                  // disk number start
    cd.setUint16(36, 0, true);                  // internal attributes
    cd.setUint32(38, 0x81ED0000, true);         // external: -rwxr-xr-x
    cd.setUint32(42, offset, true);             // local header offset
    central.push(cd.buffer, name);

    offset += 30 + name.length + f.bytes.length;
    cdSize += 46 + name.length;
    if (offset >= 0xFFFFFFFF) throw new Error('bundle too large to pack');
  }

  const eocd = new DataView(new ArrayBuffer(22));
  eocd.setUint32(0, 0x06054B50, true);          // EOCD signature
  eocd.setUint16(8, files.length, true);        // entries on this disk
  eocd.setUint16(10, files.length, true);       // entries total
  eocd.setUint32(12, cdSize, true);
  eocd.setUint32(16, offset, true);             // central dir offset
  return new Blob(parts.concat(central, [eocd.buffer]), { type: 'application/zip' });
}

// ---- directory walking (webkitGetAsEntry file-system API) --------------

// readEntries returns at most ~100 entries per call; drain the reader.
function readAllEntries(reader) {
  return new Promise((resolve, reject) => {
    const all = [];
    (function next() {
      reader.readEntries((batch) => {
        if (!batch.length) return resolve(all);
        all.push.apply(all, batch);
        next();
      }, reject);
    })();
  });
}

function entryFile(fileEntry) {
  return new Promise((resolve, reject) => fileEntry.file(resolve, reject));
}

// Flatten a directory entry into [{path, entry}] with zip-relative
// paths rooted at the dropped directory's own name.
async function walkEntries(dirEntry, prefix, out) {
  const entries = await readAllEntries(dirEntry.createReader());
  for (const entry of entries) {
    const path = prefix + '/' + entry.name;
    if (entry.isDirectory) {
      await walkEntries(entry, path, out);
    } else {
      out.push({ path, entry });
    }
  }
  return out;
}

function attach(host, opts) {
  if (!host || !opts || !opts.udid) return;
  const udid = opts.udid;
  ensureStyles();

  const overlay = document.createElement('div');
  overlay.className = 'sfd-overlay';
  overlay.innerHTML =
    '<span class="sfd-col"><span class="sfd-plus">+</span>Drop to add to device</span>';

  // Toasts are fixed to the viewport, so a bezel remount (which wipes
  // the device frame's children) can't strip them.
  let toasts = document.getElementById('sfdToasts');
  if (!toasts) {
    toasts = document.createElement('div');
    toasts.id = 'sfdToasts';
    toasts.className = 'sfd-toasts';
    document.body.appendChild(toasts);
  }

  function toast(msg, kind) {
    const t = document.createElement('div');
    t.className = 'sfd-toast sfd-' + (kind || 'busy');
    t.textContent = msg;
    toasts.appendChild(t);
    if (kind !== 'busy') {
      setTimeout(() => { t.style.opacity = '0'; }, 3200);
      setTimeout(() => { t.remove(); }, 3600);
    }
    return t;
  }

  // Mirror the live screen rect (computed fresh each time so it tracks
  // remounts, orientation, and viewport scaling) and slot the overlay
  // in as a sibling of the screen, above it.
  function showOverlay() {
    const canvas = host.querySelector('#simStreamCanvas');
    const screenArea = canvas && canvas.parentElement;
    const wrapper = screenArea && screenArea.parentElement;
    if (!wrapper || !screenArea) return;
    overlay.style.left = screenArea.style.left;
    overlay.style.top = screenArea.style.top;
    overlay.style.width = screenArea.style.width;
    overlay.style.height = screenArea.style.height;
    overlay.style.borderRadius = screenArea.style.borderRadius;
    wrapper.appendChild(overlay);
  }
  function hideOverlay() {
    if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
  }

  // dragenter/over must preventDefault for `drop` to fire. A depth
  // counter avoids flicker as the cursor crosses child elements.
  let depth = 0;
  host.addEventListener('dragenter', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    depth++;
    showOverlay();
  });
  host.addEventListener('dragover', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
  });
  host.addEventListener('dragleave', () => {
    depth = Math.max(0, depth - 1);
    if (depth === 0) hideOverlay();
  });
  host.addEventListener('drop', (e) => {
    e.preventDefault();
    depth = 0;
    hideOverlay();
    // webkitGetAsEntry must be read synchronously for every item
    // before the first await — the dataTransfer store empties once
    // the handler yields.
    const items = e.dataTransfer && e.dataTransfer.items;
    const entries = [];
    if (items && items.length && items[0].webkitGetAsEntry) {
      for (let i = 0; i < items.length; i++) {
        const entry = items[i].webkitGetAsEntry();
        if (entry) entries.push(entry);
      }
    }
    if (entries.length) {
      for (const entry of entries) {
        if (!entry.isDirectory) {
          entryFile(entry).then(upload, () => toast(entry.name + ': unreadable', 'err'));
        } else if (/\.app$/i.test(entry.name)) {
          packAndUpload(entry);
        } else {
          toast(entry.name + ": folders can't be added (only .app bundles install)", 'err');
        }
      }
      return;
    }
    // No entry API — fall back to plain files (directories can't
    // travel this path; their reads fail with a toast).
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return;
    for (let i = 0; i < files.length; i++) upload(files[i]);
  });

  // Walk a dropped .app bundle, pack it into a stored zip, and send
  // it as `<Name>.app.zip` — the Swift side extracts and installs.
  async function packAndUpload(dirEntry) {
    const busy = toast('Packing ' + dirEntry.name + '…', 'busy');
    try {
      const found = await walkEntries(dirEntry, dirEntry.name, []);
      if (!found.length) throw new Error('empty bundle');
      const files = [];
      for (const f of found) {
        const file = await entryFile(f.entry);
        files.push({ path: f.path, bytes: new Uint8Array(await file.arrayBuffer()) });
      }
      const zip = buildStoredZip(files);
      busy.remove();
      await uploadBlob(dirEntry.name + '.zip', zip, dirEntry.name);
    } catch (err) {
      busy.remove();
      toast(dirEntry.name + ': ' + (err && err.message ? err.message : 'packing failed'), 'err');
    }
  }

  function upload(file) {
    return uploadBlob(file.name, file, file.name);
  }

  async function uploadBlob(name, blob, displayName) {
    const busy = toast('Adding ' + displayName + '…', 'busy');
    try {
      const res = await fetch(
        '/devices/' + encodeURIComponent(udid) +
          '/files?name=' + encodeURIComponent(name),
        { method: 'POST', body: blob }
      );
      busy.remove();
      let body = {};
      try { body = await res.json(); } catch (_) { /* non-JSON */ }
      if (res.ok && body.ok) {
        const what = body.kind === 'app' ? 'Installed' : 'Added';
        toast(what + ' ' + displayName, 'ok');
      } else {
        toast(displayName + ': ' + (body.error || ('HTTP ' + res.status)), 'err');
      }
    } catch (err) {
      busy.remove();
      toast(displayName + ': ' + (err && err.message ? err.message : 'upload failed'), 'err');
    }
  }

  // Expose for visual verification / tests.
  return { showOverlay, hideOverlay };
}

// `pack` is exposed for visual verification / tests (round-trip a
// tree through the packer and `ditto -x -k`); the app only calls
// `attach`.

const SimFileDrop = { attach, pack: buildStoredZip };

export { SimFileDrop };
