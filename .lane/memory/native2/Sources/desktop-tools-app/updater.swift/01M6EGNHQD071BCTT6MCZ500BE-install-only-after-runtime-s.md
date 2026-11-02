---
id: 01M6EGNHQD071BCTT6MCZ500BE
anchor: '@file'
created: 2026-11-02T16:14:51Z
norm: '1'
sig: 27abcba5e975f16e
body_hash: 982615dac862f90b
raw_hash: a6b683e33b522bcc
lines: 1-256
---

install only after runtime.stop() has drained (status "stopped"); never kill an agent's in-flight call, and never relaunch while input is paused, since pausing isn't saved
