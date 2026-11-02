---
id: 01M5BHJBSX3FW866VN2HD49MRY
anchor: '@file'
created: 2026-10-20T02:17:10Z
norm: '1'
sig: 1604a1b6961a57ab
body_hash: f3fc9d789a195ba7
raw_hash: 06246ad24a3ec8d8
lines: 1-201
---

Compaction runs only in createDesktop. Waits, cell edits and notifications read execute()'s whole native shape (attributes.role, window_id, pid rows), so compacting inside execute would break them.
