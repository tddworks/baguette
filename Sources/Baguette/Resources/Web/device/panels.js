// Panels — every panel the page can open, and the one rule for opening one:
// it opens in its sheet beside the view (the view says so with
// `data-<attribute>`, its control is marked active, its sheet becomes
// reachable), is mounted the first time only, and is told when it opens
// again. A panel is a role (docs/features/web-page/design.md §3):
//
//   { name, needs, slot, attribute, mount(host, { device, control }) → handle }
//
// `slot` names its place in the page (`native<Slot>Host` / `Toggle` /
// `Sheet`); the handle may have `reopened()` and `detach()`. A panel may also
// `watch({ device, control })` from the page's start, before it ever opens
// (the network panel's armed dot). Adding a panel adds one of these; nothing
// here changes.

const VIEW = 'simNativeView';

export class Panels {
  /** `page`: finds the page's elements by id. */
  constructor(page, panels) {
    this.page = page;
    this.panels = new Map(panels.map((panel) => [panel.name, panel]));
    this.mounted = new Map();
  }

  /** Open the panel `name` for `device`, or close it when it's open. */
  toggle(name, device) {
    const panel = this.panels.get(name);
    const view = this.page.element(VIEW);
    const host = panel && this.page.element('native' + panel.slot + 'Host');
    if (!view || !host) return;
    const control = this.page.element('native' + panel.slot + 'Toggle');
    const sheet = this.page.element('native' + panel.slot + 'Sheet');
    const opening = !this.isOpen(name);
    if (opening) view.setAttribute('data-' + panel.attribute, 'open');
    else view.removeAttribute('data-' + panel.attribute);
    if (control) (opening ? control.classList.add('active') : control.classList.remove('active'));
    // Reachable only while open: a closed sheet is just faded out, so without
    // `inert` its controls would stay focusable.
    if (sheet) { sheet.setAttribute('aria-hidden', String(!opening)); sheet.inert = !opening; }
    if (!opening) return;
    const handle = this.mounted.get(name);
    if (handle) {
      if (handle.reopened) handle.reopened();
      return;
    }
    host.innerHTML = '';
    this.mounted.set(name, panel.mount(host, { device, control }) || {});
  }

  isOpen(name) {
    const panel = this.panels.get(name);
    const view = this.page.element(VIEW);
    return !!(panel && view && view.getAttribute('data-' + panel.attribute) === 'open');
  }

  /** Start every panel that watches its device — when the device can do what it needs — whether or not it ever opens. */
  watch(device) {
    for (const panel of this.panels.values()) {
      if (panel.watch && device.can(panel.needs)) panel.watch({ device, control: this.page.element('native' + panel.slot + 'Toggle') });
    }
  }

  /** The page is going: every mounted panel lets go of what it holds. */
  detach() {
    for (const handle of this.mounted.values()) {
      try { if (handle.detach) handle.detach(); } catch { /* the rest still go */ }
    }
  }

  /** The ability each panel's control needs, by the control's id. */
  needs() {
    return Object.fromEntries([...this.panels.values()].map((panel) => ['native' + panel.slot + 'Toggle', panel.needs]));
  }
}
