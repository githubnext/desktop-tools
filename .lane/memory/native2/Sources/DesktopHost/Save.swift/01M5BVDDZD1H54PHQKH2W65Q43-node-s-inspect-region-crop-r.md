---
id: 01M5BVDDZD1H54PHQKH2W65Q43
anchor: '@file'
created: 2026-10-20T05:09:14Z
norm: '1'
sig: 9cb6c3e49e9e89a4
body_hash: 7ae3eb5c4671b870
raw_hash: c5604ada3601a2bd
lines: 1-111
supersedes: 01M5BPMV7G5EDM5RAXD30WYXBP
---

Node's inspect region crop reads coordinate_context.logicalBounds, which is never set, so it always refuses; Swift's save crops correctly, an intended difference
