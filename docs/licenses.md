# Licenses

This package is MIT licensed.

The app since 0.17.0, and `desktop-tools-build --native2`, ship the pure Swift host in `native2/`. It links nothing outside the macOS SDK, but contains code ported from:

- Peekaboo: MIT.
- AXorcist: MIT, for a small part.

Their MIT notices ship with it.

The default `desktop-tools-build` builds `native/`, which links:

- Peekaboo, AXorcist: MIT.
- swift-log: Apache-2.0. Ship its NOTICE.
- swift-algorithms, swift-numerics: Apache-2.0 with the Runtime Library Exception.

Commander is resolved but not linked; its MIT license is still copied.

`desktop-tools-build` copies each notice for what its build ships into `<out>/Licenses`, and the app bundles them in `Contents/Resources/Licenses`.
