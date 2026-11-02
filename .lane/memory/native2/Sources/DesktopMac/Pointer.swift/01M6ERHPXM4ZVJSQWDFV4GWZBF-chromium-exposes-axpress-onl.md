---
id: 01M6ERHPXM4ZVJSQWDFV4GWZBF
anchor: '@file'
created: 2026-11-02T18:32:34Z
norm: '1'
sig: 27abcba5e975f16e
body_hash: 26774f711766dcfe
raw_hash: 0518e62bb9b3ac20
lines: 1-516
---

Chromium exposes AXPress only on elements with their own click listener; pages that delegate clicks at the root (jsaction, frameworks) expose nothing, so a Chromium click with no pressable candidate must fall back to a routed pointer click, which Chromium accepts in the background
