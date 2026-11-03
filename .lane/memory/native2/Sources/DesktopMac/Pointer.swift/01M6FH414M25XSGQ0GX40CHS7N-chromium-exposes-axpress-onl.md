---
id: 01M6FH414M25XSGQ0GX40CHS7N
anchor: '@file'
created: 2026-11-03T01:42:00Z
norm: '1'
sig: 27abcba5e975f16e
body_hash: e4865b3b5f0bda5a
raw_hash: 858d9a9eafac29e2
lines: 1-560
supersedes: 01M6ERHPXM4ZVJSQWDFV4GWZBF
---

Chromium exposes AXPress only on elements with their own click listener; pages that delegate clicks at the root (jsaction, frameworks) expose nothing, so a Chromium click with no pressable candidate falls back to a routed pointer click, after making the window key in its app (see 01M6FH0PW0)
