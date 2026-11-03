---
id: 01M6FH414M25XSGQ0GX40CHS7N
anchor: '@file'
created: 2026-11-03T01:42:00Z
norm: '1'
sig: 27abcba5e975f16e
body_hash: 99f766697f5cf49a
raw_hash: 2e2cf668fd7553e6
vouched: 2026-11-03T02:45:55Z
lines: 1-560
supersedes: 01M6ERHPXM4ZVJSQWDFV4GWZBF
---

Chromium exposes AXPress only on elements with their own click listener; pages that delegate clicks at the root (jsaction, frameworks) expose nothing, so a Chromium click with no pressable candidate falls back to a routed pointer click, after making the window key in its app (see 01M6FH0PW0)
