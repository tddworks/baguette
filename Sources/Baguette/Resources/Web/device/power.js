// Power — booting a device that boots (a simulator, an emulator): asked of the
// server, answered with whether it took and, when not, why.

/** The power to boot device `id`, through `wire.post`. */
export function bootThroughServer(id, wire) {
  return {
    async boot() {
      const r = await wire.post('/devices/' + encodeURIComponent(id) + '/boot');
      if (r.ok) return { ok: true, error: null };
      const body = r.json ? await r.json().catch(() => null) : null;
      return { ok: false, error: (body && body.error) || ('boot failed (HTTP ' + r.status + ')') };
    },
  };
}
