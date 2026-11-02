# Licenses

This package is MIT licensed.

Its native build, the pure Swift host in `native2/`, links nothing outside the macOS SDK, but contains code ported from:

- [Peekaboo](https://github.com/openclaw/Peekaboo): MIT.
- AXorcist: MIT, for a small part.

Their MIT notices are kept in `native2/Licenses` and ship with it: `desktop-tools-build` copies each into `<out>/Licenses`, and the app bundles them in `Contents/Resources/Licenses`.
