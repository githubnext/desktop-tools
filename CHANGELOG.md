# Changelog

Notable changes to Desktop Tools, newest first. Each release's GitHub release notes are its section here.

## [Unreleased]

### Added

- The Desktop Tools app asks once per agent, such as Claude Code or a terminal app, "Allow *name* to control this Mac?", and refuses every request from an agent you haven't allowed with `CALLER_NOT_APPROVED`, listings and captures included, without making it wait. Agents are recognized by their validated signature, or by their path when unsigned, and **Approved Agents** in the menu revokes, allows or forgets each one. After updating, each agent you use is asked about once. Recent Activity names the agent, such as `claude-code`, instead of `node`. Embedding apps opt in with `desktop_tools_set_caller_handler`. ([#120](https://github.com/githubnext/desktop-tools/pull/120))
- `desktop_fill_password` fills the focused password field. It reads a Keychain item the agent names, by service or by server (an internet password fills only a web page on that server), so macOS asks you before Desktop Tools reads it and the agent never sees the password. It can also take text from the agent, which you approve fill by fill in a Desktop Tools prompt that names the agent, the app and the site, unless you turn on **Always Allow Agent-Supplied Passwords** in the menu (off by default). It is completed when the field shows the right number of characters. Results and Recent Activity never include the password or its length, and system password prompts, such as administrator authentication, are refused. Embedding apps ask the user through `desktop_tools_set_confirmation_handlers` and set the always-allow choice with `desktop_tools_set_password_autofill`. ([#122](https://github.com/githubnext/desktop-tools/pull/122))

### Changed

- Agent input aimed at any Desktop Tools process, including another build of it, or sent while one of its prompts or menus is open, is refused with `SELF_TARGET_REFUSED`, so only the user can answer its prompts or choose Pause All Input. Agents can still observe them. ([#120](https://github.com/githubnext/desktop-tools/pull/120))
- **Behavior change:** while a password field has keyboard focus, `desktop_key` refuses keys that type characters and Command-V, and `desktop_insert` refuses all its routes, with `SECURE_FIELD_REQUIRES_FILL`. Nothing is sent. Return, Tab, Escape, arrows, Delete and other shortcuts still work. Passwords go in only through `desktop_fill_password` and its approval. ([#122](https://github.com/githubnext/desktop-tools/pull/122))

### Fixed

- Secure text fields, such as password fields, show `attributes.subrole: "AXSecureTextField"` and no value in `desktop_inspect`, `desktop_read` and `desktop_wait`, not even their mask characters; `desktop_type`, `desktop_set_value` and `desktop_select` refuse them before dispatch instead of returning `unknown`. ([#118](https://github.com/githubnext/desktop-tools/pull/118))

## [0.13.0] - 2026-10-17

### Added

- `desktop_insert` with `format: "files"` copies files into a Finder window's folder, refusing names already there, and restores the clipboard once every name appears. ([#114](https://github.com/githubnext/desktop-tools/pull/114))

## [0.12.0] - 2026-10-17

### Added

- `npm run peekaboo-test` runs Peekaboo's Swift tests without AI provider credentials in the environment, which its agent tests refuse, and stops only that run's test helpers. ([#112](https://github.com/githubnext/desktop-tools/pull/112))

### Changed

- `desktop_inspect` and `desktop_read` retry an incomplete Accessibility read once, and say `retried` when it fails again. ([#111](https://github.com/githubnext/desktop-tools/pull/111))
- `desktop_wait` also turns on Chromium and Electron web accessibility before its element and text polls, so it finds web content as inspect and read do. ([#110](https://github.com/githubnext/desktop-tools/pull/110))

## [0.11.0] - 2026-10-17

### Added

- `desktop_insert` pastes an image or files into a native text area, such as TextEdit rich text, Mail or Notes, and restores the clipboard once the attachment reads back. `clipboard: "replace"` pastes into any other receiver and leaves the item on the clipboard. ([#99](https://github.com/githubnext/desktop-tools/pull/99))
- **Pause All Input** in the app's menu refuses desktop changes and clipboard writes before dispatch, while observation keeps working. ([#100](https://github.com/githubnext/desktop-tools/pull/100))
- The app's menu lists recent agent activity: the agent, time, outcome, and app and window, without typed text or clipboard contents. ([#98](https://github.com/githubnext/desktop-tools/pull/98))
- `npm run live-check` runs the automatable live checks against the app on an unlocked Mac, using only fixtures it creates. ([#102](https://github.com/githubnext/desktop-tools/pull/102))

### Changed

- `desktop_input_source` selects through the host, so Pause All Input and the activity list cover it. ([#101](https://github.com/githubnext/desktop-tools/pull/101))
- Shorter MCP tool descriptions and schemas. The shared rules are stated once in the server instructions, and longer contracts moved to the docs' Details by tool section. ([#103](https://github.com/githubnext/desktop-tools/pull/103))

### Fixed

- `desktop_inspect` and `desktop_read` see web content in Chromium and Electron apps: the host turns on their web accessibility once per app launch. ([#107](https://github.com/githubnext/desktop-tools/pull/107))

## [0.10.0] - 2026-10-17

### Added

- `expect` on `desktop_click`, `desktop_key`, `desktop_system_key`, `desktop_drag` and `desktop_insert`: one `desktop_wait` condition that turns an `unknown` outcome into `completed` when the expected change appears. ([#89](https://github.com/githubnext/desktop-tools/pull/89))
- `desktop_input_source` lists the enabled keyboard input sources and selects one by ID, reading it back. ([#90](https://github.com/githubnext/desktop-tools/pull/90))
- `desktop_clipboard_read` with `save_path` saves the clipboard image's original PNG, JPEG or TIFF bytes. ([#96](https://github.com/githubnext/desktop-tools/pull/96))
- Setup instructions for Claude Code, Codex and other MCP clients with `npx`. ([#95](https://github.com/githubnext/desktop-tools/pull/95))

### Fixed

- A native build names the checkout it restores. The docs explain why window title bars and edges shouldn't be dragged. ([#94](https://github.com/githubnext/desktop-tools/pull/94))

## [0.9.0] - 2026-10-17

### Added

- `desktop_read` with `table: true` reads a table, outline or grid as columns and rows, with each row's element ID. ([#86](https://github.com/githubnext/desktop-tools/pull/86))
- `desktop_select` selects text in web pages through WebKit text markers. ([#88](https://github.com/githubnext/desktop-tools/pull/88))
- `desktop_set_cell` writes one table cell by row and column, and confirms it by reading the table again. ([#92](https://github.com/githubnext/desktop-tools/pull/92))

### Changed

- Recipes for zooming or rotating through an app's menu or keys instead of pinching, and shorter Finder, input source and volume recipes. ([#87](https://github.com/githubnext/desktop-tools/pull/87), [#91](https://github.com/githubnext/desktop-tools/pull/91))

## [0.8.0] - 2026-10-17

### Added

- `desktop_click` holds Command, Option or Shift, and `desktop_key` presses a sequence of keys, or one key repeatedly, against one snapshot. ([#77](https://github.com/githubnext/desktop-tools/pull/77))
- `desktop_fullscreen` enters or exits native full screen for one window. ([#78](https://github.com/githubnext/desktop-tools/pull/78))
- `desktop_set_value` sets date and time pickers from an ISO 8601 date. ([#79](https://github.com/githubnext/desktop-tools/pull/79))
- `desktop_system_key` presses media, volume and brightness keys. ([#80](https://github.com/githubnext/desktop-tools/pull/80))
- `desktop_screen` and `desktop_inspect` save their capture as a full-resolution PNG with `save_path`, optionally of one region. ([#81](https://github.com/githubnext/desktop-tools/pull/81))
- `desktop_apps` reports focus, appearance, session and input state. ([#83](https://github.com/githubnext/desktop-tools/pull/83))
- Recipes for tasks that take several tool calls. ([#84](https://github.com/githubnext/desktop-tools/pull/84))

### Changed

- `desktop_type` types into web text fields with key events, so page scripts such as React forms see the input. ([#82](https://github.com/githubnext/desktop-tools/pull/82))

## [0.7.0] - 2026-10-17

### Added

- `desktop_wait` waits until a window, dialog, element, text or app condition holds. ([#70](https://github.com/githubnext/desktop-tools/pull/70))
- When a window can't be inspected, the result says why, and which tool recovers it. ([#72](https://github.com/githubnext/desktop-tools/pull/72))
- Each display's visible frame, pixel size and rotation. ([#73](https://github.com/githubnext/desktop-tools/pull/73))
- `desktop_notifications` and `desktop_notification_action` list notifications and act on one through Notification Center's actions. ([#74](https://github.com/githubnext/desktop-tools/pull/74))

## [0.6.0] - 2026-10-17

### Added

- `desktop_spaces` lists Spaces, and `desktop_switch_space` switches a display's Space. ([#66](https://github.com/githubnext/desktop-tools/pull/66))
- `desktop_insert` types the text where no text control can be observed, as in terminals, canvases and web editors. ([#68](https://github.com/githubnext/desktop-tools/pull/68))

### Fixed

- Captures are never upscaled. ([#69](https://github.com/githubnext/desktop-tools/pull/69))

## [0.5.0] - 2026-10-17

### Added

- `desktop_drag` drags between windows and apps, holds modifier keys, and follows a path of several points. ([#52](https://github.com/githubnext/desktop-tools/pull/52), [#64](https://github.com/githubnext/desktop-tools/pull/64))
- `desktop_key` sends keys to windows whose focus isn't an observed control. ([#51](https://github.com/githubnext/desktop-tools/pull/51))
- `desktop_system_key` presses system-wide shortcuts. ([#54](https://github.com/githubnext/desktop-tools/pull/54))
- `desktop_read` reads a window's text, `desktop_inspect` inspects one subtree, and `ocr` recognizes text in captures. ([#55](https://github.com/githubnext/desktop-tools/pull/55))
- Menu commands, launches and opens report the windows they created. ([#56](https://github.com/githubnext/desktop-tools/pull/56))
- `desktop_dialog_answer` chooses a path in an exact Open or Save panel. ([#57](https://github.com/githubnext/desktop-tools/pull/57))

### Fixed

- Actions on a minimized window are refused, with a hint to restore it. ([#59](https://github.com/githubnext/desktop-tools/pull/59))
- A timed-out desktop lock names the processes holding it. ([#58](https://github.com/githubnext/desktop-tools/pull/58))
- Focusing an app that is already frontmost works, and when focus stops the result says why. ([#61](https://github.com/githubnext/desktop-tools/pull/61))
- A failed keyboard preparation says that no keys were sent. ([#62](https://github.com/githubnext/desktop-tools/pull/62))
- Captures wait out a quarantined ScreenCaptureKit gate, and a refusal explains it. ([#63](https://github.com/githubnext/desktop-tools/pull/63))

## [0.4.0] - 2026-10-17

### Added

- `desktop_hover`, and `desktop_press` to press and hold. ([#45](https://github.com/githubnext/desktop-tools/pull/45))
- `desktop_key` sends every printable key and the remaining named keys. ([#46](https://github.com/githubnext/desktop-tools/pull/46))
- `desktop_element_action` and `desktop_set_value` for non-text controls. ([#47](https://github.com/githubnext/desktop-tools/pull/47))

### Fixed

- Background Command-W, Q, H and M are refused, naming the tool to use instead. ([#49](https://github.com/githubnext/desktop-tools/pull/49))

## [0.3.0] - 2026-10-17

### Added

- An agent cursor shows background pointer input. ([#40](https://github.com/githubnext/desktop-tools/pull/40))
- `desktop_menubar_items` and `desktop_menubar_click` list and click menu bar status items, and `desktop_dock` uses the Dock. ([#41](https://github.com/githubnext/desktop-tools/pull/41))
- An outline and label mark the window the agent is using. ([#43](https://github.com/githubnext/desktop-tools/pull/43))

## [0.2.0] - 2026-10-17

### Added

- `desktop_screen` captures a whole display. ([#36](https://github.com/githubnext/desktop-tools/pull/36))
- `DESKTOP_TOOLS_STATE` lets a dev app and MCP server use their own state folder. ([#37](https://github.com/githubnext/desktop-tools/pull/37))
- `desktop_dialog` and `desktop_dialog_answer` answer dialogs, `desktop_quit` force-quits, and `desktop_hide`, `desktop_unhide` and `desktop_maximize` are added. ([#38](https://github.com/githubnext/desktop-tools/pull/38))
- A documentation site, with a page on every tool and what isn't supported. ([#32](https://github.com/githubnext/desktop-tools/pull/32), [#34](https://github.com/githubnext/desktop-tools/pull/34))

### Fixed

- The docs site links back to the repository. ([#33](https://github.com/githubnext/desktop-tools/pull/33))
- Removed a Chrome window-title limitation from the docs; it no longer applies. ([#35](https://github.com/githubnext/desktop-tools/pull/35))

## [0.1.0] - 2026-10-16

### Added

- The first release: a signed, notarized Desktop Tools menu bar app, and the desktop tools served over MCP. ([#28](https://github.com/githubnext/desktop-tools/pull/28), [#29](https://github.com/githubnext/desktop-tools/pull/29), [#12](https://github.com/githubnext/desktop-tools/pull/12))

[Unreleased]: https://github.com/githubnext/desktop-tools/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/githubnext/desktop-tools/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/githubnext/desktop-tools/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/githubnext/desktop-tools/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/githubnext/desktop-tools/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/githubnext/desktop-tools/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/githubnext/desktop-tools/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/githubnext/desktop-tools/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/githubnext/desktop-tools/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/githubnext/desktop-tools/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/githubnext/desktop-tools/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/githubnext/desktop-tools/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/githubnext/desktop-tools/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/githubnext/desktop-tools/releases/tag/v0.1.0
