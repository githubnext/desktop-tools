---
id: 01M6ERHPXM4ZVJSQWDFV4GWZBF
anchor: '@file'
created: 2026-11-02T18:32:34Z
norm: '1'
---

Chromium exposes AXPress only on elements with their own click listener; pages that delegate clicks at the root (jsaction, frameworks) expose nothing, so a Chromium click with no pressable candidate must fall back to a routed pointer click, which Chromium accepts in the background
