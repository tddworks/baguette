// Devices — this server's devices, as the page asks about them: Swift's
// `Devices`, over its routes. The role every family is handed (never the
// routes themselves):
//
//   listing(id)              → its listing (kind, abilities, state), or null
//   definition(id)           → its definition (bezel, screen)
//   definitionURL(id, chrome)→ where its definition is, in a borrowed chrome
//   boot(id)                 → { ok, error }
//   simulators()             → the simulators the server lists
//   framesFitting(w, h)      → the Mac frames that fit a screen of that size

const path = (id, rest) => '/devices/' + encodeURIComponent(id) + rest;

/** The devices of the server the page came from, through `fetch`. */
export function serverDevices(fetch) {
  const json = async (url) => {
    const r = await fetch(url, { cache: 'no-store' });
    if (!r.ok) throw new Error(url + ' answered ' + r.status);
    return r.json();
  };
  return {
    async listing(id) {
      try { return await json(path(id, '/device.json')); } catch { return null; }
    },
    definition: (id) => json(path(id, '/definition.json')),
    definitionURL: (id, chrome) => path(id, '/definition.json') + (chrome ? '?chrome=' + encodeURIComponent(chrome) : ''),
    async boot(id) {
      const r = await fetch(path(id, '/boot'), { method: 'POST' });
      if (r.ok) return { ok: true, error: null };
      const body = await r.json().catch(() => null);
      return { ok: false, error: (body && body.error) || ('boot failed (HTTP ' + r.status + ')') };
    },
    simulators: () => json('/simulators.json'),
    async framesFitting(width, height) {
      const fit = await json('/mac-frames.json?width=' + width + '&height=' + height);
      return (fit && fit.frames) || [];
    },
  };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._Devices = { serverDevices };
}
