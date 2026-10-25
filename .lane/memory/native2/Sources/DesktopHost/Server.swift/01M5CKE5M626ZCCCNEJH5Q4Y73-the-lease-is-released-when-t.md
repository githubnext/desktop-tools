---
id: 01M5CKE5M626ZCCCNEJH5Q4Y73
anchor: '@file'
created: 2026-10-20T12:09:04Z
norm: '1'
sig: 0fd09e8458d728cc
body_hash: f6b7b7b0ce3366d6
raw_hash: 6c2029ec908e6351
vouched: 2026-10-24T23:32:49Z
lines: 1-202
---

the lease is released when the last call ends after stop, not at stop, so a restarting runtime must await drained() before starting the next Server or its start fails with SocketOwned
