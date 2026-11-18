---
description: How baguette unit-tests Resources/Web/ JavaScript with node:test, and the rich-domain class style the tested pieces follow.
---

# JS testing (`Resources/Web/`)

Small, reusable pieces of `Resources/Web/` logic are unit-tested with Node's built-in `node:test` — zero new dependencies. `make test-web` (or `node --test 'Tests/Web/**/*.test.js'`) runs them. `Tests/Web/helpers/load-browser-module.js` loads a plain `<script src>` IIFE file into a throwaway `window` and returns it — via `vm.runInThisContext`, not `vm.createContext` (a fresh VM context is a separate JS realm with its own `Object`/`Array` prototypes, which silently breaks `assert.deepEqual`'s prototype check on anything the loaded module returns). Production files stay bundler-free, unchanged.

Rich domain, JS-flavored: `class` with `static` factories/utilities plus instance methods for behaviour on a constructed value — mirrors Swift's `static func` + instance methods on a `struct`. `new DeviceFilter(criteria).apply(devices)`, `new FarmFilter(opts).apply(devices)`, `quad.locate(px, py)` on a `ScreenQuad`, `bands.classify(point, orientation)` on `EdgeBands`. Behaviour lives on the value; callers don't reach into raw fields or manually AND together separate predicates. No generic `domain/`/`utils/` bucket folder — each class lives in the feature-topic folder it actually belongs to, same as `parts/` and `gestures/` already group by topic: `ScreenQuad` / `EdgeBands` / `GestureEnvelope` in `baguette/gestures/`; `DeviceFilter` beside `sim-list.js` in `sim-list/`; `FarmFilter` beside the rest of `farm/`.

Page composition, DOM rendering, and WebSocket lifecycle (`sim-native.js`, `sim-location.js`, the `Screen`/`Transport`/`PointerInterpreter` orchestrators themselves) stay integration-only, like Swift's `Internal/System/` calls — the page's shell is its bare I/O. Extract a new testable unit opportunistically when touching one of these files; it's not a standalone sweep target.

Test names follow the same rule as Swift ([Naming tests](tdd-patterns.md#naming-tests)): `test('should <outcome> [when <situation>]', …)` in the viewer's language — `test('should treat a touch near the bottom edge as a home swipe in portrait', …)`, not `test('classifies a point in the bottom hot zone as "bottom"', …)`.
