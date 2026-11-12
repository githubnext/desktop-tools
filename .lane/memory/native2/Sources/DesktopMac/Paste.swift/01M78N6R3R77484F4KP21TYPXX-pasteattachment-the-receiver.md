---
id: 01M78N6R3R77484F4KP21TYPXX
anchor: '@file'
created: 2026-11-12T19:54:24Z
norm: '1'
supersedes: 01M5D5AB34JDWZ565DVTAB86HD
---

pasteAttachment: the receiver check comes before requireKeyboardFocus so a background web field gets PASTE_UNVERIFIABLE_RECEIVER, as on Node, not a focus refusal. pasteText instead prepares the window first, since a web field's text paste can be read back (#5)
