// PluginControl — what ticking a row in a plugin panel means.
//
// Before this, a plugin wanting a settings list wrote its state into the
// row title: display.py shipped `"● Light"` / `"○ Dark"`. That is a
// plugin drawing a control glyph inside a string, in a page whose whole
// premise is that the host owns every pixel. Escaping made it safe, not
// right — the host couldn't style it, a screen reader read a bullet, and
// "which one is on" was legible only to a human eye.
//
// So a row says whether it is on (`state`) and what it submits
// (`value`); the manifest says which glyph family draws it; and this
// file says what clicking does.
//
//   "body": { "kind": "list", "source": "perms",
//             "control": { "kind": "checkbox", "arg": "enabled",
//                          "submit": "Apply" } }
//
// Ticking is LOCAL and batched. It costs no subprocess: the panel
// accumulates ticks and posts them together when the submit button is
// pressed, as `{"args": {"enabled": ["camera", "mic"]}}`. The trade is
// that between the tick and the answer, a row shows state the device has
// not confirmed — so `pending` exists, and the host marks those rows
// rather than letting them look settled. A control that lies about the
// device is worse than one that's slow.
//
// Ticks are plain objects passed in and returned, never held here: the
// renderer owns the current set, this file only says what the next one
// should be. That keeps every decision testable without a DOM, the same
// arrangement page/plugins/plugin-row-action.js and page/plugins/plugin-prompt.js use.
(function (root) {
  'use strict';

  class PluginControl {
    /** @param {object|undefined} spec  the panel body's `control` */
    constructor(spec) {
      this.spec = spec || null;
    }

    /**
     * Whether this panel has tickable rows at all.
     *
     * A control naming no `arg` is treated as absent. The host refuses
     * such a manifest, but the page must not lean on that — ticks with
     * nowhere to post would be a control that flips and changes nothing.
     */
    get present() {
      return !!(this.spec && typeof this.spec.arg === 'string' && this.spec.arg
                && PluginControl.kinds.includes(this.spec.kind));
    }

    /**
     * Which glyph family the host draws: switch / checkbox / radio.
     *
     * Resolved against the closed set rather than passed through. The
     * Swift parser already restricts it, but this file must not lean on
     * that: `/plugins.json` is the same untrusted manifest text every
     * other string here is escaped for, and `kind` is interpolated
     * straight into `data-control` and `role` attributes — one malformed
     * value would close the attribute and open one of its own. Same
     * treatment `SEVERITIES` gets in page/plugins/plugins-rail.js.
     */
    get kind() {
      return this.present ? this.spec.kind : null;
    }

    /** The submit button's label. A label is chrome, so it defaults. */
    get submitLabel() {
      return (this.spec && this.spec.submit) || 'Apply';
    }

    /**
     * Whether `row` is a control rather than a header or a plain note.
     *
     * Both halves are required: `state` says it has an on/off, `value`
     * says what ticking it submits. A row with neither renders as it
     * always did, which is how a settings panel keeps its section
     * headings.
     */
    isControlRow(row) {
      if (!this.present) return false;   // no control declared, or one we can't draw
      return !!(row && (row.state === 'on' || row.state === 'off') && row.value);
    }

    /**
     * The starting ticks: what the device last reported.
     *
     * Not an empty set — a panel that opened showing every setting off
     * would be describing a machine that doesn't exist, and inviting you
     * to "fix" it.
     */
    initialTicks(rows) {
      const ticks = {};
      if (!this.present) return ticks;
      for (const row of rows || []) {
        if (this.isControlRow(row)) ticks[row.value] = row.state === 'on';
      }
      return ticks;
    }

    /**
     * The ticks after clicking `row`. Returns a new object — the
     * renderer still holds the previous one to compare against, and
     * mutating in place would make "what changed" unanswerable.
     *
     * A radio turns its **group's** siblings off and cannot be turned
     * off by re-clicking: "nothing chosen" is a state the device can't
     * be in, so offering it would be offering a lie.
     *
     * The group is what makes a radio panel usable for more than one
     * question. A settings panel is normally several independent choices
     * at once — appearance, contrast and text size all at once — and
     * without groups, picking "Dark" would silently unpick the text
     * size. Rows naming no group share one implicit group, which is the
     * single-question panel.
     */
    toggle(ticks, row, rows) {
      if (!this.present || !this.isControlRow(row)) return { ...ticks };
      if (this.kind !== 'radio') {
        return { ...ticks, [row.value]: !ticks[row.value] };
      }
      const next = { ...ticks };
      for (const sibling of rows || []) {
        if (!this.isControlRow(sibling)) continue;
        if ((sibling.group || null) !== (row.group || null)) continue;
        next[sibling.value] = false;
      }
      next[row.value] = true;
      return next;
    }

    /**
     * Values whose tick disagrees with what the device reported — the
     * rows that are showing an unconfirmed edit.
     *
     * This is the cost of batching made visible. The host draws these
     * differently so you can tell a setting you asked for from a setting
     * the device actually has.
     */
    pending(ticks, rows) {
      if (!this.present) return [];
      return (rows || [])
        .filter((row) => this.isControlRow(row))
        .filter((row) => !!ticks[row.value] !== (row.state === 'on'))
        .map((row) => row.value);
    }

    /** Whether there is anything to submit. */
    changed(ticks, rows) {
      return this.pending(ticks, rows).length > 0;
    }

    /**
     * The `args` object for the current ticks, or `null` when the panel
     * has no control.
     *
     * **Always an array**, including for a radio, which yields one
     * element — one shape means a plugin has one branch to write rather
     * than a scalar case it discovers by reading the docs twice. An
     * empty array is a real instruction ("turn all of these off"), not a
     * no-op, so it is submitted rather than collapsed away.
     *
     * Ordered by row order so the plugin sees a stable list rather than
     * whichever sequence the ticks happened to be clicked in.
     */
    args(ticks, rows) {
      if (!this.present) return null;
      const on = (rows || [])
        .filter((row) => this.isControlRow(row))
        .filter((row) => !!ticks[row.value])
        .map((row) => row.value);
      return { [this.spec.arg]: on };
    }
  }

  /// The glyph families this page can draw, mirroring `RowControl` in
  /// Plugins/Plugin/PanelBody.swift. A closed set on both sides: the host
  /// refuses an unknown one at parse time, and the page refuses to
  /// render one it was somehow handed anyway.
  PluginControl.kinds = ['switch', 'checkbox', 'radio'];

  root.Baguette = root.Baguette || {};
  root.Baguette._PluginControl = PluginControl;
})(window);
