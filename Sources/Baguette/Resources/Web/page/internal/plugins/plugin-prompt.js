// PluginPrompt — what a panel's text field means.
//
// Every panel before this one was a report: the host ran a command and
// drew what came back. A deep-link bar can't work that way, because the
// interesting value is the one nobody has typed yet. A panel may declare
// a `prompt`, and submitting it invokes that panel's own `source`
// command with the typed text under the key the manifest named:
//
//   "prompt": { "arg": "url", "placeholder": "myapp://path",
//               "submit": "Open", "filter": true }
//
// which posts `{"args":{"url":"<typed>"}}` — the same body a
// `rowAction: "run"` click posts, to the same endpoint. So this is a
// widget, not a new execution model, and no plugin code runs in the page.
//
// Split out of page/internal/plugins/plugins-rail.js so the decisions are testable without a
// DOM, exactly as page/internal/plugins/plugin-row-action.js is: this file says what should
// happen, page/internal/plugins/plugins-rail.js does it.
(function (root) {
  'use strict';

  class PluginPrompt {
    /** @param {object|undefined} spec  the panel body's `prompt` */
    constructor(spec) {
      this.spec = spec || null;
    }

    /**
     * Whether to draw a field at all.
     *
     * A prompt naming no `arg` is treated as absent rather than drawn.
     * The host refuses such a manifest, but the page must not lean on
     * that — a field that submits into nowhere looks exactly like a
     * working control and does nothing.
     */
    get present() {
      return !!(this.spec && typeof this.spec.arg === 'string' && this.spec.arg);
    }

    /** Greyed hint inside the empty field. */
    get placeholder() {
      return (this.spec && this.spec.placeholder) || '';
    }

    /** The submit button's label. A label is chrome, so it defaults. */
    get submitLabel() {
      return (this.spec && this.spec.submit) || 'Run';
    }

    /** Whether typing also narrows the rows already on screen. */
    get filters() {
      return !!(this.spec && this.spec.filter);
    }

    /** Whether the field finishes your sentence as you type. */
    get completes() {
      return !!(this.spec && this.spec.complete);
    }

    /** Whether what you submit is remembered for `↑` / `↓`. */
    get remembers() {
      return !!(this.spec && this.spec.history);
    }

    /**
     * Everything the bar may complete to, best guess first.
     *
     * History leads: `account://hello` is a thing you actually did,
     * `account://` is merely a scheme that exists on the device. Rows
     * follow in the order the plugin ranked them. Deduped, because a
     * link you used *and* that is installed is one candidate, not two.
     */
    candidates(rows, history) {
      const out = [];
      const seen = new Set();
      const add = (text) => {
        const value = String(text == null ? '' : text);
        if (!value || seen.has(value)) return;
        seen.add(value);
        out.push(value);
      };
      for (const entry of history || []) add(entry);
      for (const row of rows || []) add(row && (row.fill || row.title));
      return out;
    }

    /**
     * The part of the best candidate you haven't typed yet — drawn
     * greyed after the caret, and what `Tab` / `→` accepts.
     *
     * Empty unless the panel asked for completion, and empty for an
     * empty field: a bar that starts guessing before you've typed
     * anything is noise.
     */
    ghost(value, candidates) {
      if (!this.completes) return '';
      const typed = String(value == null ? '' : value);
      if (!typed) return '';
      const lower = typed.toLowerCase();
      const hit = (candidates || []).find(
        (c) => c.length > typed.length && c.toLowerCase().startsWith(lower)
      );
      return hit ? hit.slice(typed.length) : '';
    }

    /**
     * The field's value once the ghost is accepted.
     *
     * Built by appending the remainder to what was typed rather than
     * swapping in the candidate, so typing `ACC` completes to
     * `ACCount://hello` — the bar finishes your word instead of
     * rewriting it under the caret.
     */
    accepted(value, candidates) {
      const typed = String(value == null ? '' : value);
      return typed + this.ghost(typed, candidates);
    }

    /**
     * `history` with `value` at the front. A link you re-open moves up
     * rather than appearing twice, and the list is capped so it stays a
     * shortlist you can arrow through rather than a log.
     */
    remember(history, value) {
      const existing = history || [];
      if (!this.remembers) return existing;
      const entry = String(value == null ? '' : value).trim();
      if (!entry) return existing;
      return [entry, ...existing.filter((e) => e !== entry)]
        .slice(0, PluginPrompt.historyLimit);
    }

    /**
     * The `args` object for what was typed, or `null` when there is
     * nothing to send — a blank submit would spawn a subprocess only to
     * be told the field was empty.
     *
     * Trimmed, because pasting a link routinely brings a trailing
     * newline and echoing it back untrimmed makes the answer look wrong.
     */
    args(value) {
      if (!this.present) return null;
      const trimmed = String(value == null ? '' : value).trim();
      if (!trimmed) return null;
      return { [this.spec.arg]: trimmed };
    }

    /**
     * Whether `row` survives what's typed so far.
     *
     * Only when the manifest asked for it. A command is a subprocess
     * with a bounded budget, so re-running it per keystroke is the wrong
     * shape — but the rows it already returned are right here, and
     * narrowing them locally gives back the feel of completion for the
     * price of a string comparison. A panel that didn't ask keeps every
     * row: its list is a reference, not a search result.
     */
    matches(row, value) {
      if (!this.filters) return true;
      const needle = String(value == null ? '' : value).trim().toLowerCase();
      if (!needle) return true;
      if (!row) return false;

      // `fill` is searched alongside the display fields: it is the text
      // that actually goes into the box, while a title may be decorated
      // or translated. Searching only the label hides the completion
      // whenever the two differ.
      const hay = [row.title, row.subtitle, row.fill]
        .filter(Boolean).join(' ').toLowerCase();
      if (hay.includes(needle)) return true;

      // A suggestion you have typed *past* stays visible. Picking
      // `account://` fills the box and then you type the path; on a
      // substring test alone the row you just picked would vanish at the
      // next character and the list would read "Nothing matches" for the
      // rest of the URL — the list fighting the thing it exists to help
      // with. Matched against `fill` where a row has one, since that's
      // the text that actually went into the field.
      const own = String(row.fill || row.title || '').toLowerCase();
      return !!own && needle.startsWith(own);
    }
  }

  /// How many submissions a panel keeps. Long enough to arrow back to
  /// this morning's link, short enough that arrowing through it is
  /// faster than retyping.
  PluginPrompt.historyLimit = 25;

  root.Baguette = root.Baguette || {};
  root.Baguette._PluginPrompt = PluginPrompt;
})(window);
