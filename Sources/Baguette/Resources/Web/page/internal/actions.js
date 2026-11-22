// The page's actions: each control says what it does (`data-action`, and
// `data-arg` when it takes one); each concern registers its own verbs; one
// listener runs the verb a click names. A new control is its markup and one
// registration — nothing else on the page changes.

/** `'true'` / `'false'` are the flags they spell; anything else is as written. */
function argument(raw) {
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  return raw;
}

export function pageActions() {
  const verbs = new Map();
  const actions = {
    /** Register what `name` does. */
    on(name, fn) { verbs.set(name, fn); },
    has: (name) => verbs.has(name),
    /** Run `name` with `arg`; nothing for a verb no one registered. */
    run(name, arg) {
      const fn = verbs.get(name);
      if (fn) fn(argument(arg));
    },
    /** Run the verb of each control clicked inside `root`. */
    listen(root) {
      root.addEventListener('click', (event) => {
        const control = event.target && event.target.closest && event.target.closest('[data-action]');
        if (control) actions.run(control.dataset.action, control.dataset.arg);
      });
    },
  };
  return actions;
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._PageActions = { pageActions };
}
