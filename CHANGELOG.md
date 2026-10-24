# Changelog

Notable changes to Desktop Tools, newest first. Each release's GitHub release notes are its section here.

## [Unreleased]

### Added

- `desktop_insert` and `desktop_scroll` take `foreground: true` for windows background input can't reach, such as a web page in a window that doesn't keep keyboard focus while the agent's terminal is in front. The app is brought forward, the text is typed with real keys or the scroll is sent as real wheel ticks with the pointer over the target, and the pointer and the previously focused window are given back. Results are unknown, with `read_back` (the control's value) or `content_moved`. The default stays background, and the refusals that pointed typing at `desktop_set_value` now name this option. ([#177](https://github.com/githubnext/desktop-tools/issues/177), [#197](https://github.com/githubnext/desktop-tools/issues/197))

### Fixed

- `desktop_inspect` takes its screenshot after reading the window's Accessibility tree, not during it. Reading some SwiftUI lists makes them load rows and grow, which moved content after the screenshot was taken, so a point read off it could click whatever moved under it. An inspection takes about as long as its tree read longer. ([#159](https://github.com/githubnext/desktop-tools/issues/159))
- `return` is accepted as a key name wherever keys are named (`desktop_key`, `desktop_system_key`), as an alias of `enter`. `desktop_system_key` results name the app that was frontmost when the keys were sent (`frontmost`), and `desktop_wait`'s description states its argument rules: `element_appears` and `element_gone` need an element with a role plus a title, value or identifier, and `timeout_ms` is an integer from 100 to 45000. ([#199](https://github.com/githubnext/desktop-tools/issues/199))
- An open menu's window, such as a SwiftUI `MenuBarExtra` status item's NSMenu or one of its submenus, can be inspected: `desktop_inspect` reads the open `AXMenu` and lists its items with `checked` for a checkmark, so they can be clicked by element. `desktop_menubar_click` on an item whose menu is open closes the menu without choosing an item (`closed_menu`), and `desktop_element_action` `AXCancel` on the menu closes it too. A window opened by a status item is `inspectable` only when it has Accessibility elements to read. ([#193](https://github.com/githubnext/desktop-tools/issues/193))
- Typing refused because secure keyboard entry is on now names the app and window holding it (`secure_input_holder`: pid, name, bundle ID, window title), read from the window server's session, such as a system password dialog behind the target, and asks to have the user dismiss it. ([#176](https://github.com/githubnext/desktop-tools/issues/176))
- `desktop_scroll` scrolls web content it used to refuse with "no supported route". A Chrome or other Chromium page gets arrow keys, one per unit, at the window's keyboard focus when that focus is on the page and not in a field, and the result reads back that the page moved; with focus in a field it is refused with a hint to click the page or send `desktop_key` `pagedown`. A WKWebView app that loads WebKit from a library beside its executable, such as an Electrobun app, gets the background wheel Safari gets. ([#197](https://github.com/githubnext/desktop-tools/issues/197), [#201](https://github.com/githubnext/desktop-tools/issues/201))
- `desktop_type` into a web field reads the field back until it settles, up to 2 seconds, so a busy page such as a React filter is confirmed instead of reported `TYPING_UNVERIFIED`. When the field still doesn't match, the error says what it read back, in `read_back`. Replacing a Chrome field's text no longer appends to it: Chrome ignores a background Command-A, so the field's text is also selected through Accessibility, and typing stops with the field's contents reported when it can't be cleared. ([#203](https://github.com/githubnext/desktop-tools/issues/203))
- The signed `desktop-tools-client` and `desktop-tools-mcp` check the host again before sending anything: a process at the socket path that isn't the same user's and signed by the same team gets no requests, and the call fails with `HOST_UNTRUSTED`. The Peekaboo-based client did this, and docs/embed.md still said so. ([#191](https://github.com/githubnext/desktop-tools/issues/191))
- The app and `desktop-tools-build --native2` ship Peekaboo's and AXorcist's MIT notices again, in `Licenses/`, since the Swift host contains code ported from them. docs/licenses.md describes native2. ([#192](https://github.com/githubnext/desktop-tools/issues/192))
- When `npx` runs `desktop-tools-mcp` against a Desktop Tools app of another version that has no MCP server of its own (before 0.17.0), every failed call names both versions and says to install the matching app, since updating the `npx` tag doesn't update the app. ([#179](https://github.com/githubnext/desktop-tools/issues/179))
### Changed

- An agent run as a background job, with no terminal or app above it, is asked about as the nearest program signed by a developer team that runs it, such as Claude Code, and the prompt says it's a program, not an app. When there is no such program, the refusal says so and why, instead of only that the caller couldn't be identified. A caller's team counts only when Apple issued its certificate. Setup docs note that background jobs don't load nvm. ([#194](https://github.com/githubnext/desktop-tools/issues/194))

## [0.17.1] - 2026-10-20

### Fixed

- `desktop_select` selects text in a web page that isn't a field, such as a paragraph or a link, through WebKit's text markers. An image pasted into a web field is refused with `PASTE_UNVERIFIABLE_RECEIVER` before the focus check, since the page's handling can't be read back. ([#88](https://github.com/githubnext/desktop-tools/issues/88), [#99](https://github.com/githubnext/desktop-tools/issues/99))
- Text selected in a Safari page with `desktop_select` can be copied: selecting focuses the page, as a click would, so Edit > Copy in the activated Safari copies the selection instead of the page's address. Safari copies only while active, so `desktop_activate` it and choose Edit > Copy with `desktop_menu`; the tool description and docs said to press Command-C, which Safari ignores in the background. ([#188](https://github.com/githubnext/desktop-tools/issues/188))

## [0.17.0] - 2026-10-20

### Changed

- The app runs a pure Swift host in place of the Peekaboo Bridge runtime, and bundles its own MCP server, `Desktop Tools.app/Contents/MacOS/desktop-tools-mcp`. Set agents up with that path; Node is no longer needed. Calls are faster, for example `desktop_windows` at a p50 of 6 ms instead of 115 ms and an inspection of a Ghostty window at 42 ms instead of 551 ms, and results have the same text. The app's binaries are about 6 MB in place of 84 MB. ([#143](https://github.com/githubnext/desktop-tools/issues/143))
- An `npx` setup of `desktop-tools-mcp` at v0.17.0 or later hands over to the app's server. A setup pinned to an earlier tag no longer works with this app: its calls are refused with `CLIENT_OUTDATED`, naming the app's server to set up instead. ([#143](https://github.com/githubnext/desktop-tools/issues/143))
- `desktop-tools-build --native2` builds the Swift host, client, MCP server and app without Peekaboo; embedders switch with it and `createDesktop({ wire: 2 })`. The default build is unchanged. ([#171](https://github.com/githubnext/desktop-tools/issues/171))

### Known gaps

- `desktop_switch_space` is checked only on a Mac with one Space.
- Where MenuBarAgent doesn't draw the menu bar, `desktop_menubar_items` lists and clicks status items through their WindowServer windows. This path is unit-tested but not yet checked live.

## [0.16.1] - 2026-10-19

### Fixed

- The window outline no longer draws over a sheet or Open panel that opens on top of its window, such as an Open panel on System Settings' Search Privacy sheet. The window server keeps a window's sheets with it, so the outline is cut away under them, and it follows them as they open and close. ([#149](https://github.com/githubnext/desktop-tools/issues/149))
- `desktop_dialog` and `desktop_dialog_answer` read and answer an Open panel stacked on a sheet, such as the one **+** opens on System Settings' Search Privacy sheet. With the app or the parent window as the target, they picked neither and refused the target as ambiguous; the innermost dialog, which the others wait on, is now the one chosen. ([#148](https://github.com/githubnext/desktop-tools/issues/148))
- A point click on a control below a list that grows as it's read, such as **Search Privacy…** in System Settings > Spotlight, presses it. Finding the control read the whole pane, which made the app list longer and moved the button off the point, so the click was refused as finding no pressable element. ([#147](https://github.com/githubnext/desktop-tools/issues/147))

## [0.16.0] - 2026-10-19

### Added

- `desktop_select` selects text on a PDF page in Preview. It was refused because the page's text reports itself disabled and has no selection until one is set. To copy it, activate Preview and choose Edit > Copy, since Preview disables Copy in the background. ([#130](https://github.com/githubnext/desktop-tools/issues/130))

### Changed

- Results are compact, so an agent's context fills far more slowly: the restore, focus, inspect and click loop on a TextEdit window went from 34,721 characters to 5,543. Elements list their fields once, with bounds as `[x, y, width, height]`, real booleans and state only when set; window and app rows keep their target and drop the fields it repeats; detection metadata, timings, diagnostics, coordinate context and checked receipts are left out. A large window lists more of its 200 elements, since the limit applies to the compact result. See [Result shape](docs/tools.md#result-shape). `DESKTOP_TOOLS_VERBOSE=1`, or `verbose` in the client config, returns native results whole. ([#144](https://github.com/githubnext/desktop-tools/issues/144))
- Window actions (focus, restore, minimize, maximize, full screen, move, resize) return the window's refreshed row instead of the app's whole window inventory and an inspection with a screenshot; inspect before input. ([#144](https://github.com/githubnext/desktop-tools/issues/144))
- `desktop_windows` counts the untitled off-screen windows that most apps keep, such as menu bar strips, in `hidden_windows` instead of listing them; `all: true` lists them. ([#144](https://github.com/githubnext/desktop-tools/issues/144))
- The agent's name label under the window outline is a point smaller and tighter, and edged in a darker shade of the outline color instead of white.
- Peekaboo is vendored in `native/vendor/Peekaboo`, with our changes applied, instead of fetched and patched at build time. Native builds no longer fetch Peekaboo, and `npm run peekaboo-test` runs the vendored tests without `--scratch`. `git diff peekaboo-upstream-4d43dc9 -- native/vendor/Peekaboo` shows our changes to upstream.

### Fixed

- A point click on a sheet that Accessibility only lists inside its parent window, such as the **+** in System Settings > Spotlight > Search Privacy, or **Cancel** in the Open panel it opens, reaches the sheet. It was refused as occluded by the parent, although nothing covered the sheet. ([#141](https://github.com/githubnext/desktop-tools/issues/141))
- A point click that finds no pressable element, or an element in a window covering the target, is `refused` instead of `unknown`, since nothing was sent, and the message no longer suggests a `--foreground` option the tools don't have. The occlusion refusal names the window it found. ([#141](https://github.com/githubnext/desktop-tools/issues/141))

## [0.15.0] - 2026-10-19

### Added

- `desktop-client status` and `desktop-client repair`, run from a shell through the link in the state folder, show whether the app serves its socket and fix it when it doesn't, by opening the app and waiting for it to serve. See [Keeping the socket served](docs/app.md#keeping-the-socket-served). ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- `desktop_tools_check()` in the runtime's C ABI checks the socket now, for an embedding app to call when it is opened again. ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- The Desktop Tools app has an icon, a placeholder for now, in Finder, its disk image and its prompts. ([#135](https://github.com/githubnext/desktop-tools/pull/135))
- A recipe for picking from a `<select>` in Chrome and other Chromium browsers: one `desktop_key` call with Down to open the menu, Down to the option and Enter, in the background. Clicking or `AXPick` on its menu items is refused there, because the menu closes between tool calls. ([#139](https://github.com/githubnext/desktop-tools/pull/139))

### Changed

- The Desktop Tools menu is shorter. Agent activity moved from Recent Activity and All Activity to a log, `activity.log` in the state folder, which **Open Log** opens. The log keeps every operation, not just the last 20, and also notes when the app starts, with its socket, and when you pause input or allow or refuse an agent. The socket path is no longer in the menu, **Serve agents** is gone (Pause All Input, Quit or Approved Agents do what it did), granted permissions are no longer listed (a **Grant** item shows only while one is missing), and **Pause All Input** sits just above Quit. Embedding apps can write the same log with `desktop_tools_set_log`. ([#132](https://github.com/githubnext/desktop-tools/pull/132))

### Fixed

- Desktop Tools keeps retrying when it can't start serving, such as when it reopens while the copy that is quitting still holds the socket. It used to stop at the first failure and refuse every call until it was quit and reopened. The menu's status line shows the error and when it retries next. ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- Desktop Tools no longer quits when an agent closes its connection before the reply. A write to the closed connection raised SIGPIPE, which killed the app and left its socket behind, so every later call failed until it was opened again. ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- Desktop Tools publishes its socket again when something removes or replaces it while it serves. Before, the app kept running with no socket, and every call failed with "Open Desktop Tools" until it was quit and reopened. Opening the app while it runs now checks the socket too. ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- When a call finds no app serving the socket, the client opens Desktop Tools in the background, waits up to 10 seconds for it to serve, and then runs the call. Before, an app that wasn't running or wasn't serving needed the user to notice and restart it. When that doesn't help, calls fail with `HOST_NOT_RUNNING` or `HOST_NOT_SERVING`, saying what the client found, instead of `Connection refused` or "Open Desktop Tools". ([#140](https://github.com/githubnext/desktop-tools/pull/140))
- Only one Desktop Tools app runs for each state directory. A second one, such as the app binary run from a shell, exits with a message instead of taking over the first one's socket. `desktop-tools-app --version` prints the version, and other arguments are refused. ([#140](https://github.com/githubnext/desktop-tools/pull/140))

## [0.14.1] - 2026-10-17

### Fixed

- The agent cursor sits directly above the window the agent is using instead of above every window, so a window covering that app covers the cursor too. Input outside any one window, such as on the Dock or the menu bar, still shows it on top. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- The agent window outline and its label stay on the display when the window fills it; they were drawn just outside the window and ran off the screen's edges. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- `desktop_close` on a Finder window is `completed` again instead of `unknown`: Accessibility lists Finder's desktop as a window without an ID, which made every close unverifiable on macOS 27, even after the window was gone. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- `desktop_wait` and `expect` app conditions with `bundle_id` find the app when many apps are running; the app list cut to fit a result could drop it, and a cut list no longer counts as proof that an app quit. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- `desktop_read` with `table: true` finds the column titles of web tables in Safari 27, which reports `<th>` cells as plain cells. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- `desktop_select` in Safari 27 web text no longer crashes the Desktop Tools app, and finds text bounds without the text marker attributes Safari dropped. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- Pasting files with `desktop_insert` into a Finder window on macOS 27 finds the window's folder from its path bar, since Finder no longer reports it otherwise; without the path bar, the refusal says to turn on View > Show Path Bar. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- `desktop_set_value` on a Safari 27 date input is refused before input, with a hint to type the date, instead of `unknown`; it accepts an ISO 8601 date where a date can be set. ([#133](https://github.com/githubnext/desktop-tools/pull/133))
- Management failures, such as an unverified `desktop_close`, include the native `cause`, as action failures do. ([#133](https://github.com/githubnext/desktop-tools/pull/133))

## [0.14.0] - 2026-10-17

### Added

- The Desktop Tools app asks once per agent, such as Claude Code or a terminal app, "Allow *name* to control this Mac?", and refuses every request from an agent you haven't allowed with `CALLER_NOT_APPROVED`, listings and captures included, without making it wait. Agents are recognized by their validated signature, or by their path when unsigned, and **Approved Agents** in the menu revokes, allows or forgets each one. After updating, each agent you use is asked about once. Recent Activity names the agent, such as `claude-code`, instead of `node`. Embedding apps opt in with `desktop_tools_set_caller_handler`. ([#120](https://github.com/githubnext/desktop-tools/pull/120))
- `desktop_fill_password` fills the focused password field. It reads a Keychain item the agent names, by service or by server (an internet password fills only a web page on that server), so macOS asks you before Desktop Tools reads it and the agent never sees the password. It can also take text from the agent, which you approve fill by fill in a Desktop Tools prompt that names the agent, the app and the site, unless you turn on **Always Allow Agent-Supplied Passwords** in the menu (off by default). It is completed when the field shows the right number of characters. Results and Recent Activity never include the password or its length, and system password prompts, such as administrator authentication, are refused. Embedding apps ask the user through `desktop_tools_set_confirmation_handlers` and set the always-allow choice with `desktop_tools_set_password_autofill`. ([#124](https://github.com/githubnext/desktop-tools/pull/124))

### Changed

- `desktop_inspect` keeps containers an agent can scope into, such as a Finder window's file list after its long sidebar, when its result is cut to size, dropping other elements first. ([#126](https://github.com/githubnext/desktop-tools/pull/126))
- Agent input aimed at any Desktop Tools process, including another build of it, or sent while one of its prompts or menus is open, is refused with `SELF_TARGET_REFUSED`, so only the user can answer its prompts or choose Pause All Input. Agents can still observe them. ([#120](https://github.com/githubnext/desktop-tools/pull/120))
- **Behavior change:** while a password field has keyboard focus, `desktop_key` refuses keys that type characters and Command-V, and `desktop_insert` refuses all its routes, and `desktop_menu` refuses Paste commands (found by their Command-V shortcut, whatever the title), with `SECURE_FIELD_REQUIRES_FILL`. Nothing is sent. Return, Tab, Escape, arrows, Delete and other shortcuts still work. Passwords go in only through `desktop_fill_password` and its approval. ([#124](https://github.com/githubnext/desktop-tools/pull/124))

### Fixed

- `desktop_click` with `modifiers`, such as Command-click or Shift-click, no longer fails its cleanup every time with `DESKTOP_ACTION_FAILED` and "cursor restoration … could not be verified": the host read the pointer back before its restoring move had landed. It reports `cursor_restoration` again and stays `unknown` with `DESKTOP_ACTION_UNVERIFIED`, since a modifier click's effect can't be confirmed. ([#128](https://github.com/githubnext/desktop-tools/pull/128))
- `desktop_clipboard_read` with `save_path` saves images again; the host never enabled image export, so every such read was refused. The build now fails if the host would drop an operation the app allows. ([#125](https://github.com/githubnext/desktop-tools/pull/125))
- A clipboard paste whose receiver never took it, such as an image pasted into a TextEdit `.rtf` document, no longer blocks every clipboard write and paste until that app quits: closing the receiving window releases it too, and the refusal says so. ([#125](https://github.com/githubnext/desktop-tools/pull/125))
- `window_appears` no longer counts a window macOS keeps listed but ordered out on the current Space as open, so `expect` with `window_appears` for Spotlight works on macOS 27, where Siri AI (`com.apple.campo`) hosts the panel. ([#125](https://github.com/githubnext/desktop-tools/pull/125))
- Command-A in a text field is `completed` again instead of `unknown` with a receipt mismatch: the client checked the host's receipt for a layout-resolved key without the keyboard layout, which only the main thread can read. ([#126](https://github.com/githubnext/desktop-tools/pull/126))
- Finder windows with a long sidebar keep their focused file list in observations, so `desktop_insert` with `format: "files"` pastes into them instead of being refused for having no focused control. ([#126](https://github.com/githubnext/desktop-tools/pull/126))
- Renaming a file through Finder's Name column with `desktop_set_cell`, or its name field with `desktop_type` or `desktop_set_value`, used to report `completed` while Finder only showed the new name and never renamed the file. It is now refused before input with `CELL_NOT_EDITABLE`. ([#126](https://github.com/githubnext/desktop-tools/pull/126))
- A `desktop_key` sequence that stops partway reports `KEY_SEQUENCE_STOPPED` whatever stopped it, as when Command-N moves focus to a new window, instead of a bare `DESKTOP_ACTION_FAILED`, and says when the key that stopped it may have been sent. ([#126](https://github.com/githubnext/desktop-tools/pull/126))
- `desktop_read` with `table: true` no longer reports a role description such as "cell", "column" or "image" as cell text or a column title, or a folder's disclosure triangle as `0` in its Name cell, and names a sorted column by its title rather than its sort direction. ([#126](https://github.com/githubnext/desktop-tools/pull/126))

## [0.13.1] - 2026-10-17

### Fixed

- Secure text fields, such as password fields, show `attributes.subrole: "AXSecureTextField"` and no value in `desktop_inspect`, `desktop_read` and `desktop_wait`, not even their mask characters; `desktop_type`, `desktop_set_value` and `desktop_select` refuse them before dispatch instead of returning `unknown`. ([#118](https://github.com/githubnext/desktop-tools/pull/118))
- `desktop_inspect`, `desktop_read` and `desktop_wait` see Chrome 155's web content again: Chrome now rejects `AXManualAccessibility`, so the host falls back to `AXEnhancedUserInterface` for apps that ship Chromium, and results name the one used in `web_accessibility_via`. An app that accepts neither now reports `unsupported` instead of `unknown`. ([#119](https://github.com/githubnext/desktop-tools/pull/119))

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

[Unreleased]: https://github.com/githubnext/desktop-tools/compare/v0.17.1...HEAD
[0.17.1]: https://github.com/githubnext/desktop-tools/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/githubnext/desktop-tools/compare/v0.16.1...v0.17.0
[0.16.1]: https://github.com/githubnext/desktop-tools/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/githubnext/desktop-tools/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/githubnext/desktop-tools/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/githubnext/desktop-tools/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/githubnext/desktop-tools/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/githubnext/desktop-tools/compare/v0.13.0...v0.13.1
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
