---
id: 01M7975EN9Y94PY508R9YP15Y3
anchor: '@file'
created: 2026-11-13T01:08:16Z
norm: '1'
sig: 78473a106add9cfc
body_hash: a87250ce9513086f
raw_hash: 2c4435891c3ad43e
lines: 1-982
supersedes: 01M6EGHDDEY51YSVQ7T6TS53SX
---

this text is what native2 serves: scripts/contract.mjs compiles it into ContractText.swift through dist/mcp.js --wire 2, so regenerate after editing it; CI fails when they differ. Until #237 flips the source, make the same change in native2/Sources/DesktopProtocol/ContractTools.swift, whose test fails otherwise
