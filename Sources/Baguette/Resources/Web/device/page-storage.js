// The page's storage: the browser's, or — when the browser refuses it outright
// (reading `localStorage` throws) — one that remembers nothing, so the page
// still loads and every pick simply lasts the visit.

const FORGETFUL = { getItem: () => null, setItem() {}, removeItem() {} };

/** `browser`: the window. */
export function pageStorage(browser) {
  try {
    return browser.localStorage || FORGETFUL;
  } catch {
    return FORGETFUL;
  }
}
