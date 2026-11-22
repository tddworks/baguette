// A panel whose view is one of the old attach-style classes (`new View()`,
// `attach(host, udid)`, `refresh()`, `detach()`): its handle, for `Panels`.
// `refreshes`: whether it re-reads the device each time it opens again.

/** Mount `window[name]` into `host` for `device`; `prepare` sets it up first. */
export function mountView(name, host, device, { refreshes = false, prepare } = {}) {
  const view = new window[name]();
  if (prepare) prepare(view);
  view.attach(host, device.id);
  return {
    reopened: refreshes ? () => view.refresh() : undefined,
    detach: () => view.detach(),
  };
}
