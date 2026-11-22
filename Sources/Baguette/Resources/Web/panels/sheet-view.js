// A panel whose view is one of the old attach-style classes (`new View()`,
// `attach(host, udid)`, `refresh()`, `detach()`): its handle, for `Panels`.
// `refreshes`: whether it re-reads the device each time it opens again.

/** Mount a `View` into `host` for `device`; `prepare` sets it up first. */
export function mountView(View, host, device, { refreshes = false, prepare } = {}) {
  const view = new View();
  if (prepare) prepare(view);
  view.attach(host, device.id);
  return {
    reopened: refreshes ? () => view.refresh() : undefined,
    detach: () => view.detach(),
  };
}
