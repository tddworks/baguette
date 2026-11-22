// A Mac display's pointer, drawn by the page: the display streams without it
// (so it never trails the hand), a mouse moving over the screen moves it
// (hover), and it takes the Mac's real shape as it changes. Its parts are
// LocalPointer, HoverGestureSource and PointerShape.
// docs/features/mac-screen/README.md#input.

import { LocalPointer } from './local-pointer.js';
import { PointerShape } from './pointer-shape.js';
import { HoverGestureSource } from '../../../baguette/gestures/hover-gesture-source.js';

/** The pointer, made of the parts that draw it, follow the mouse and take its shape. */
export function macPointerWith({ LocalPointer, HoverGestureSource, PointerShape }) {
  return {
    /** Draw it over `view`'s screen (`screenArea`, and `screen` for hover). */
    follow(view) {
      const pointer = LocalPointer.attach(view.screenArea);
      new HoverGestureSource(view.screen).attach(view.screenArea);
      PointerShape.follow((shape, density) =>
        pointer.setShape({ ...shape, cursor: PointerShape.cursor(shape, density) }));
    },
  };
}

export const macPointer = macPointerWith({ LocalPointer, HoverGestureSource, PointerShape });
