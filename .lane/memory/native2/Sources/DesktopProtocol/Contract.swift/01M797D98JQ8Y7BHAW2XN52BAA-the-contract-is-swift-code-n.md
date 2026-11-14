---
id: 01M797D98JQ8Y7BHAW2XN52BAA
anchor: '@file'
created: 2026-11-13T01:12:33Z
norm: '1'
sig: 55aac2c2aa641984
body_hash: 723f0b9a2c9a5955
raw_hash: 532816b183b930cb
lines: 1-47
---

The contract is Swift code, not a resource file: the embedded dylib and the bundled MCP binary run from app and Ace bundles where SwiftPM's Bundle.module lookup finds no resource bundle and crashes on first use
