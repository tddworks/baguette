// A Mac display's pointer, drawn by the page: the display streams without it
// (so it never trails the hand), a mouse moving over the screen moves it
// (hover), and it takes the Mac's real shape as it changes. Its parts are the
// page's classic modules: LocalPointer, HoverGestureSource, PointerShape.
// docs/features/mac-screen/README.md#input.

export const macPointer = {
  /** Draw it over `view`'s screen (`screenArea`, and `screen` for hover). */
  follow(view) {
    const B = window.Baguette;
    const pointer = B._LocalPointer.attach(view.screenArea);
    new B._HoverGestureSource(view.screen).attach(view.screenArea);
    B._PointerShape.follow((shape, density) =>
      pointer.setShape({ ...shape, cursor: B._PointerShape.cursor(shape, density) }));
  },
};
