// PreferenceRows — the Defaults card's rows, and the requests it sends, as
// plain values. No DOM, no fetch: what the server read back goes in, rows and
// request bodies come out, so the card itself only draws and sends.
//
// The card stays a dumb sender. Types are never inferred here: every value
// arrives tagged (`{"type": …, "value": …}`) and goes back out with the type
// it was read as, and Swift validates it. An array or dictionary is edited as
// the plist text the server sent alongside it (`plist=1`), so this file never
// has to know plist either. See `docs/features/defaults/README.md`.
(function (root) {
  'use strict';

  const TEXT_TYPES = ['int', 'float', 'string', 'date'];

  function plural(n, one) {
    return `${n} ${one}${n === 1 ? '' : 's'}`;
  }

  /** Base64 length → the size of the bytes it encodes, for display. */
  function size(base64) {
    const bytes = Math.floor((String(base64 || '').length * 3) / 4);
    return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} KB`;
  }

  function row(key, tagged) {
    const type = tagged.type;
    if (type === 'bool') return { key, type, control: 'switch', checked: tagged.value === true };
    if (TEXT_TYPES.includes(type)) return { key, type, control: 'text', text: String(tagged.value) };
    if (type === 'data') return { key, type, control: 'data', summary: size(tagged.value) };
    const count = type === 'array' ? (tagged.value || []).length : Object.keys(tagged.value || {}).length;
    return {
      key, type, control: 'plist',
      summary: type === 'array' ? plural(count, 'item') : plural(count, 'key'),
      text: tagged.plist || '',
    };
  }

  /** A setting the running app reads that nothing stores. Its value comes
   *  from a registered fallback (`source: 'registered'`, shown) or from the
   *  app's own code (`source: 'app'`, which no one outside the app can
   *  see). An untyped read asks for a type before a value. */
  function unsetRow(lookup) {
    const { key } = lookup;
    const type = lookup.type || null;
    const registered = lookup.registered;
    const source = registered ? 'registered' : 'app';
    if (type === 'bool') {
      return { key, type, control: 'switch', source, checked: !!registered && registered.value === true };
    }
    if (TEXT_TYPES.includes(type)) {
      return {
        key, type, control: 'text', source, text: '',
        placeholder: registered ? String(registered.value) : "app's default",
      };
    }
    return { key, type, control: 'pick', source };
  }

  /** The keys the running app watches, so a change reaches it at once. */
  function liveKeys(read) {
    return new Set((read && read.lookups && read.lookups.live) || []);
  }

  /** `true` / `false` / `'whenNeeded'` as the server reads it. */
  function relaunchWire(relaunch) {
    return relaunch === 'whenNeeded' ? 'whenNeeded' : !!relaunch;
  }

  const PreferenceRows = {
    /** `GET defaults.json?…&plist=1` → rows in key order, each marked
     *  `live` when the running app watches its key. */
    fromRead(read) {
      const values = (read && read.values) || {};
      const live = liveKeys(read);
      return Object.keys(values).sort().map((key) => ({ ...row(key, values[key]), live: live.has(key) }));
    },

    /** Stored values that differ from the last read — added or changed —
     *  so the card can show the app writing them. Nothing on a first read. */
    changedKeys(before, after) {
      if (!before.length) return [];
      const was = new Map(before.map((r) => [r.key, JSON.stringify([r.type, r.text, r.checked, r.summary])]));
      return after
        .filter((r) => was.get(r.key) !== JSON.stringify([r.type, r.text, r.checked, r.summary]))
        .map((r) => r.key)
        .sort();
    },

    /** Rows whose key or type contains `text`, ignoring case. */
    filter(rows, text) {
      const needle = String(text || '').trim().toLowerCase();
      if (!needle) return rows;
      return rows.filter((r) => r.key.toLowerCase().includes(needle) || String(r.type || '').includes(needle));
    },

    /** Whether a running app said which settings it reads — false when it
     *  wasn't launched by baguette, so the card can offer a relaunch. */
    answered(read) {
      return !!(read && read.lookups && read.lookups.answered);
    },

    /** The settings the running app reads that nothing stores, in the
     *  order the server sent (key order). */
    unsetFromRead(read) {
      if (!PreferenceRows.answered(read)) return [];
      const live = liveKeys(read);
      return (read.lookups.unset || []).map((lookup) => ({ ...unsetRow(lookup), live: live.has(lookup.key) }));
    },

    /** One value, posted as the type it was read as; arrays and
     *  dictionaries go back as their plist text. */
    writeBody({ bundleId, suite, key, type, value, relaunch }) {
      const body = { bundleId };
      if (suite) body.suite = suite;
      body.key = key;
      body.type = type === 'array' || type === 'dict' ? 'plist' : type;
      body.value = value;
      body.relaunch = relaunchWire(relaunch);
      return body;
    },

    /** An imported file: an export's `values`, or a bare map as it is. */
    importBody({ bundleId, suite, file, relaunch }) {
      const body = { bundleId };
      if (suite) body.suite = suite;
      body.values = file && typeof file.values === 'object' ? file.values : file;
      body.relaunch = relaunchWire(relaunch);
      return body;
    },

    /** Query string for the read / delete / groups routes. */
    query({ bundleId, suite, key, relaunch, plist }) {
      const parts = [`bundleId=${encodeURIComponent(bundleId)}`];
      if (suite) parts.push(`suite=${encodeURIComponent(suite)}`);
      if (key !== undefined && key !== null) parts.push(`key=${encodeURIComponent(key)}`);
      if (relaunch === 'whenNeeded') parts.push('relaunch=whenNeeded');
      else if (relaunch) parts.push('relaunch=1');
      if (plist) parts.push('plist=1');
      return parts.join('&');
    },

    exportFileName({ bundleId, suite }) {
      return `${bundleId}${suite ? `.${suite}` : ''}.defaults.json`;
    },

    /** A failed request as a card-level notice. The server's message is
     *  the text, because it already names the step to take; the status only
     *  picks the tone, and a shut-down simulator offers to boot it. */
    notice(status, error) {
      return {
        tone: status === 404 ? 'warn' : 'danger',
        text: error || `Request failed (${status})`,
        action: status === 409 ? 'boot' : null,
      };
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._PreferenceRows = PreferenceRows;
})(window);
