# Tools

The [MCP server](mcp.md) and `desktopTools()` expose 47 tools, one per protocol operation. Each tool's description in `src/tools.ts` says, in a few sentences, what it does, whether it is foreground or background input, when its result is `completed` rather than `unknown`, and its main refusal and recovery. Rules shared by every tool, such as single-use snapshots and never replaying input, are in the MCP server's instructions. This page holds the details. The client validates every argument, so the schemas name fields and keep only the limits that help choose values.

[Recipes](recipes.md) give tool sequences, derived from the code, for tasks that take several calls, such as printing to PDF, installing from a DMG or filling a web form.

Targets are exact: an app target binds a process generation, and a window target binds its window ID and bounds. Input acts on a single-use snapshot from the latest `desktop_inspect`. A stale or changed target is refused rather than redirected. Action results report `completed`, `refused`, or `unknown`, and nothing is retried automatically. The Desktop Tools app refuses every call from an agent the user hasn't allowed with `CALLER_NOT_APPROVED`, and input aimed at its own prompts, menus and windows, or sent while one of its prompts or menus is open, with `SELF_TARGET_REFUSED`; see [approved agents](app.md#approved-agents).

## Find and observe

| Tool | Does |
| --- | --- |
| `desktop_apps` | List running apps, optionally filtered by name or bundle ID |
| `desktop_windows` | List one app's windows, each with whether it can be observed and acted on now, and why not |
| `desktop_inspect` | Read one window's Accessibility elements and a screenshot, or only pixels when Accessibility is unavailable; returns the snapshot that input uses. `scope` lists one element's subtree from a much larger read, and `ocr` adds recognized text |
| `desktop_read` | Read the text of one window, or of one inspected element's subtree, through Accessibility, up to 96 KB including content scrolled out of view; or, with `table`, one table's columns and rows; read only, with no snapshot |
| `desktop_wait` | Wait, up to 45 seconds, until a window, dialog, element, text or app condition holds, then return what matched; read only. Some actions take the same condition as `expect` |
| `desktop_screen` | Capture one whole display and list the displays and the windows on it, front to back; observation only, with no input snapshot. `ocr` adds recognized text |
| `desktop_menus` | Read an app's menu bar structure without opening it |
| `desktop_dialog` | Read the open dialog or sheet in an app or window: its buttons, text fields and labels |
| `desktop_clipboard_read` | Read the clipboard as text, an image, or file references; optionally save the image's original file |

Each `desktop_windows` row has an `availability` object with a `state` (`available`, `limited` or `unavailable`), a `reason`, and a `hint` naming the tool that recovers it. Nothing is recovered automatically.

| Reason | Means | Recovery |
| --- | --- | --- |
| `session_locked` | The Mac's session is locked | Unlock it, then observe again |
| `display_asleep` | The window's display is asleep | Wake the display |
| `minimized` | The window is minimized | `desktop_restore` |
| `app_hidden` | The app is hidden | `desktop_unhide` |
| `other_space` | The window is on another Space than its display's current one; `space_id` names it | `desktop_switch_space`, or `desktop_focus` or `desktop_activate`, which switch Spaces |
| `off_screen` | The window's bounds are on no display | `desktop_move` |
| `not_on_screen` | macOS reports it off screen for no reason the listing shows | `desktop_focus` |
| `accessibility_unavailable` | It's on screen, but Accessibility can't see it (`limited`) | Wait briefly if it just opened, or inspect with `mode: "pixels"` |

When `desktop_inspect`, `desktop_read` or an action is refused, the result's `target_availability` carries the same classification, read from a fresh listing after the failure. A window that looks available but failed with an incomplete Accessibility tree, as while a web view first loads, is `sparse_accessibility`. `desktop_inspect` and `desktop_read` already wait a second and read once more after an incomplete Accessibility tree, within their 30-second budget; when that also fails, the error says `retried: true`. A page still loading may fill in after a few more seconds; otherwise use pixels mode and OCR. A window missing from the listing is `window_gone`. The classification names the likely cause; it can't prove it.

Captures go through ScreenCaptureKit, which every Peekaboo process for the user shares one call at a time. When an earlier capture timed out and hasn't returned, which usually means another capture on the Mac is busy, a new capture waits up to 2 seconds for it. If it still hasn't returned, the capture is refused with a message saying the problem is temporary; wait a few seconds and inspect again. There is no fallback capture, because every other capture path would also use ScreenCaptureKit while the abandoned call still runs. `desktop_apps` has 2.5 seconds to read the app inventory and is refused, not cut short, when the Mac is too busy to finish in time.

`desktop_wait` replaces polling `desktop_inspect` or `desktop_windows` after slow work such as a launch, a page load, an export or a dialog opening. Each call waits for one condition (`until`):

- `window_appears`: an app, by `bundle_id` or `pid`, has a window that is on screen, minimized or on a Space, optionally with an exact `title` or a `title_contains` substring. `window_gone`: the window `pid` and `window` is no longer listed, or its app quit.
- `dialog_appears`, `dialog_gone`: `desktop_dialog` finds a dialog, alert or sheet in app `pid`, or in its window `window`, or finds none.
- `element_appears`, `element_gone`: an element of window `pid` and `window` matches `element`, an exact role and at least one of an exact title, value or identifier.
- `text_changes`, `text_equals`, `text_contains`: the window's text, a `scope`'s text, or the value of the one element `element` matches, differs from the first poll, equals `text` or contains it.
- `app_running`, `app_frontmost`, `app_quit`: an app, by `bundle_id` or `pid`, is running, is the active app, or no longer runs.

The wait polls with backoff, from 200 ms up to 2 seconds between polls, for `timeout_ms` (10 seconds by default, 45 at most), and returns `matched` with what matched or `timed_out` with the last observation. It sends no input and never activates an app. Each poll is a separate read, so the wait holds no lock between polls, and other agents' operations run in between. Element and text polls read the window through Accessibility only, with `desktop_read`'s budget and no screenshot, so they don't use ScreenCaptureKit. Absence is reported only when it is certain: a traversal cut short never counts as an element being gone, a partial inventory never counts as a window or app being gone, and a dialog counts as gone only when Accessibility reached every window of the app. Matched windows and apps come as `desktop_windows` and `desktop_apps` rows with their targets. When an element appears, the wait inspects the window once more (with the `scope`, if given) and returns that snapshot's ID and the matching elements' IDs, which the action tools accept; when the inspection doesn't list the element, its `snapshot_id` is null and the agent must inspect before acting.

`desktop_click`, `desktop_key`, `desktop_system_key`, `desktop_drag` and `desktop_insert` take an optional `expect`: one `desktop_wait` condition with its arguments, naming what the action should change. Examples are `element_appears` for a menu that a click opens, `app_frontmost` for an app that Command-Tab brings forward, `window_appears` for Spotlight, or `text_changes` for a terminal that typed text goes to.
- **Before input.** The condition is read once. If it already holds, the action is refused with nothing sent, because a match afterward couldn't show what the action did. If the condition can't be read reliably, the action is likewise refused.
- **Unknown outcome.** The host polls the condition for `timeout_ms`: 3 seconds by default, 10 at most.
  - If the condition holds, the outcome becomes `completed`. `action.native_outcome` keeps `unknown`, and `expectation` shows the match, including a fresh snapshot for `element_appears`.
  - If it doesn't hold in time, the outcome stays `unknown`, with `expectation.last_observation`.
- **Completed or refused outcome.** The result comes back as it is, with no polling.

The input is sent once and never repeated. Another action opts in by adding its op to `DESKTOP_EXPECT_OPS` and `expect` to its schema.

## Apps and windows

| Tool | Does |
| --- | --- |
| `desktop_launch` | Launch or activate an app by path or bundle ID |
| `desktop_open` | Open a file, folder, app or URL, optionally in a chosen app |
| `desktop_activate` | Bring an app to the front |
| `desktop_hide`, `desktop_unhide` | Hide an app, or unhide and bring it to the front |
| `desktop_quit` | Ask an app to quit normally, or with `force: true` terminate it and lose all unsaved work |
| `desktop_focus` | Bring one window to the front |
| `desktop_minimize`, `desktop_restore` | Minimize or unminimize one window |
| `desktop_maximize` | Zoom one window to fill the visible screen area, without entering full screen |
| `desktop_fullscreen` | Enter or exit native full screen for one window, which gives it a Space of its own |
| `desktop_move`, `desktop_resize` | Set one window's origin or size in desktop points |
| `desktop_close` | Ask one window to close normally |

Window operations other than focus use background Accessibility and don't activate the app. `desktop_fullscreen` sends no input either, but macOS switches the display to the window's new full-screen Space, and back when it exits; the result names that Space as in `desktop_spaces`, and is `completed` only when the window reads back in the requested state. `desktop_unhide` activates the app, because macOS has no exact background unhide.

`desktop_launch`, `desktop_open` and `desktop_menu` report `created_windows`: the app's windows that weren't there just before the request was sent, each with its target for `desktop_inspect`. They wait up to about one second for a menu command and two for a launch or open. `attribution` is `exclusive` when exactly one window appeared, `ambiguous` when several did, and `none` when none did in time. When two agents work in the same app at once, `exclusive` is very likely but not certain to be the agent's own window, since the other agent's window can appear in the same interval; `ambiguous` means nothing tells them apart.

## Spaces

| Tool | Does |
| --- | --- |
| `desktop_spaces` | List each display's Spaces left to right, with the current one, each Space's kind (desktop or full-screen app) and the windows assigned to it |
| `desktop_switch_space` | Switch one display to a listed Space with Mission Control's keyboard shortcuts, and read the Spaces back |

`desktop_spaces` reads WindowServer and sends no input. Its windows carry pid, window ID and app name but no title; `desktop_windows` rows have the same `space_ids`, plus titles and targets. A window assigned to all desktops is listed on each Space.

Both `desktop_spaces` and `desktop_screen` describe each display: its `desktop_screen` index, name, whether it is the main display (index 0, which holds the menu bar and the coordinate origin), `bounds` and `visible_bounds` in global desktop points with a top-left origin, as window bounds use, `scale` (pixels per point), `pixel_width` and `pixel_height`, and `rotation` in degrees. `visible_bounds` is what is left after the menu bar and Dock, the area `desktop_maximize` fills; a display left of or above the main one has negative coordinates. `desktop_spaces` reads this without a capture, so prefer it when only the arrangement is needed.

`desktop_apps` also returns `system`, the desktop-wide state worth checking before acting. `focus` names the frontmost app, its frontmost window and its focused element by role, title, identifier and bounds, which is where keyboard input and `desktop_system_key` would land; the element's value is never included, so field contents stay behind `desktop_read`. `appearance` gives dark or light mode, automatic switching, the accent color and the accessibility display settings that change how apps draw. `session` says whether the screen is locked, the screensaver runs, every display sleeps, or secure keyboard entry is on, which refuses typed text. `input` gives the keyboard layout, which `desktop_key` uses to find character keys, and the pointer's position and display. `menu_bar_autohides` and `dock_autohides` explain `visible_bounds`. Everything but the focused element comes from the client process without Accessibility; that one read goes through the host with its own 300 ms limit, after the inventory, so a slow app leaves `focus.element` null with a warning instead of delaying the call. Focus modes such as Do Not Disturb have no public read and are not reported.

`desktop_switch_space` is foreground input. It presses Move left a space or Move right a space (Control-Left and Control-Right by default) once per step, reading the Spaces back after each, and reports `completed` only when WindowServer shows the target Space as current. Otherwise the result is `unknown` and names the Space that is current now. macOS applies those shortcuts to the display that holds the pointer or the key window, so with separate Spaces per display the switch is refused before any key unless both are on the target Space's display. `focus` in `desktop_spaces` shows where they are; use `desktop_hover` to move the pointer and `desktop_focus` to bring a window there forward. It is also refused when either shortcut is turned off or rebound to something other than an arrow key with modifiers in Keyboard Shortcuts > Mission Control.

Mission Control and App Exposé are `desktop_system_key` with `control` and `up` or `down`.

## Menu bar and Dock

| Tool | Does |
| --- | --- |
| `desktop_menubar_items` | List the menu bar's status items left to right, with owner app, pid and process generation, identifier, title and bounds |
| `desktop_menubar_click` | Press one status item by its exact listed target, then list and capture the windows that opened |
| `desktop_notifications` | List the notification banners and alerts on screen, and Notification Center's entries when it is open, with app, title, body and actions |
| `desktop_notification_action` | Open, close or run one listed action of one notification, then read again to confirm it went away |
| `desktop_dock` | List the Dock; launch or activate one item by exact title, or right-click it and choose a context-menu item by exact title |

A status item is pressed through Accessibility in its owner process without moving the pointer. Control Center, Notification Center and many popovers open as windows that `desktop_inspect` can read and drive; an app's plain status menu may show only in the click's capture. The Dock right-click is a real mouse event that moves the physical pointer.

## Input

| Tool | Does |
| --- | --- |
| `desktop_click` | Single, double, right, middle or triple click on an element or a screenshot point, optionally holding Command, Option or Shift |
| `desktop_scroll` | Scroll an element or point up, down, left or right |
| `desktop_drag` | Press, move in a straight line or along a path of up to 16 points, and release inside one window, or into another window or app; optionally hold modifier keys |
| `desktop_hover` | Move the real pointer over an element or point, to show tooltips and hover states |
| `desktop_press` | Press and hold an element or point for up to 10 seconds, then release in place |
| `desktop_type` | Replace an editable field's whole value; a web text field is typed into with key events so the page sees the input |
| `desktop_fill_password` | Fill the focused password field from a Keychain item, or with agent-supplied text the user approves; the password never appears in results |
| `desktop_select` | Select literal text in a field or a web page, or put the caret before or after it |
| `desktop_set_cell` | Write one cell of a table from `desktop_read`, by row and column, and confirm it by reading the table again |
| `desktop_set_value` | Set a slider, stepper or level indicator to a number, a checkbox, switch or disclosure triangle on or off, or a date or time picker to an ISO 8601 date, and read it back |
| `desktop_element_action` | Perform one Accessibility action an element lists, such as `AXShowMenu`, `AXIncrement`, `AXDecrement`, `AXPick` or `AXCancel` |
| `desktop_insert` | Insert text, an image or files at the caret or over the selection with one temporary paste, then restore the clipboard; where no text control can be observed, type text into the window's keyboard focus |
| `desktop_key` | Press one key with optional Command, Control, Option and Shift: any character key, such as `,` or `/`, or a named key; or a sequence of up to 16 keys, or one key up to 32 times |
| `desktop_system_key` | Press one system-wide shortcut, such as Command-Space or Control-Up, on whatever is frontmost, or one media, volume or brightness key |
| `desktop_input_source` | List the enabled keyboard input sources, or select one by its ID and read it back |
| `desktop_menu` | Run one menu command by its exact title path |
| `desktop_dialog_answer` | Press one dialog button by its exact title, replace one dialog text field's value, or choose a path in an Open or Save panel |
| `desktop_clipboard_write` | Replace the clipboard with text, an image, or file references |

Pointer input is delivered to the exact window without moving the physical pointer, except for `desktop_hover` and a `desktop_drag` with `to_snapshot` or `modifiers`. Hover effects follow the real pointer, so it moves the user's pointer and leaves it there. Before moving, it checks that the snapshot's window is still at the same place and frontmost at the point, and refuses otherwise. Afterward, it checks that the pointer arrived and the window is still frontmost there; if either can't be confirmed, the result is `unknown`. A drag into another window or app can't stay inside one window, so it also uses the real pointer, and pressing in the source may bring its app forward. Pass the destination's snapshot as `to_snapshot`. Both points must be uncovered at their snapshot positions, or the drag is refused before input. The pointer rests on the start point, then presses, pauses, moves, rests over the destination and releases. The result is always `unknown`; inspect both windows to see whether the drop happened. A drag with `modifiers`, such as Option to copy or Command to move in Finder, or Shift to constrain, holds the real keys system-wide from before the press until after the release, so it takes the same foreground route even within one window, and its result is `unknown` too. Don't drag a window's title bar or edge to move or resize it: such a drag may be delivered without moving the window, and nothing reads the bounds back. Use `desktop_move` and `desktop_resize`, which set the window's bounds directly. A `path` adds up to 16 points visited in order in straight segments; it works in both routes within one window but not with `to_snapshot`. `desktop_press` holds the button through the same exact-window route as a drag, and the host always releases it, even when the call is interrupted or the window changes. When the host turns on the agent cursor, an orange arrow first glides to each click, scroll, drag, hover or press point, about a third of a second before the input is sent. It then shows a ripple for clicks, chevrons for scrolls and a trail for drags. For a press, it stays squeezed until the button is released, then ripples. The cursor fades after a few seconds idle. The cursor never takes clicks or focus and is left out of `desktop_inspect` and `desktop_screen` captures. It is decoration only: if it fails or is slow, input proceeds unchanged after at most 600 ms. Keyboard input, `desktop_type` and `desktop_select` don't show it.

When the host turns on the window highlight, the window an inspection or action targets gets an orange outline and a label such as "Claude is using TextEdit". It shows from the moment the request reaches the host, moves to a new window when the target changes, and fades about four seconds after the last request. The outline follows the window as it moves or resizes and stays directly above it in the window order, so windows in front of the target also cover the outline. It hides while the window is minimized, off screen or on another Space. Like the cursor, it never takes clicks or focus and is left out of captures. Requests without one exact window, such as `desktop_screen`, menus or the clipboard, don't show it.

`desktop_key` goes to the control the snapshot reports as focused. When there is none, as in Finder lists, outlines, tables, canvases and many web areas, it goes to whatever has keyboard focus in that window; the result's `receiver` is `observed_control` or `window_focus`. Either way the key is sent in the background, and is refused unless the app's focused element is still inside the window, and the window is still the app's key window, before each event.

A `desktop_click` with `modifiers` (any of `command`, `option` and `shift`), such as Command-click or Shift-click to extend a selection in Finder or Mail, is foreground input even on an element, because an Accessibility press ignores modifier keys. The host activates the app, moves the real pointer to the point (an element's observed center), holds the keys with real key events around a real click, then restores the pointer and the previously focused app and window; the result reports `cursor_restoration` and `focus_restoration`. Nothing reads back what the click selected, so its result is `unknown`. A Control-click is a right click: use `kind: "right"` without modifiers. Modifiers work with single, double and triple clicks.

`desktop_key` takes `keys`, a sequence of up to 16 chords each with its own modifiers, or `repeat` with one `key` to press it up to 32 times, all against one snapshot. Every key of a sequence goes to the window's keyboard focus, since focus may move as it runs (as Tab does), and before each one the host checks that the app's focused element is still in this window and that it is still the app's key window. The sequence stops at the first refused key; `keys_sent` says how many went, and a sequence that stopped early is `unknown`.

`desktop_key` takes a character key as the character it types, and finds that key on the current keyboard layout, so `,` is the comma key on any layout. A character that needs Shift or Option, such as `?` or `A`, is refused with the key and modifier to send instead (`/` with `shift` on a US layout); the key press never holds a modifier that wasn't asked for. The named keys are `enter`, `tab`, `escape`, `space`, `backspace`, `delete` (forward delete), `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `help` (Insert on PC keyboards), `f1` to `f20`, and the keypad keys `keypad0` to `keypad9`, `keypaddecimal`, `keypadplus`, `keypadminus`, `keypadmultiply`, `keypaddivide`, `keypadequals`, `keypadenter` and `keypadclear`. Dead keys, such as `´` on some layouts, can't be pressed alone; use `desktop_insert` for text. Command-W, Command-Q, Command-H and Command-M are refused before anything is sent; `desktop_close`, `desktop_quit`, `desktop_hide` and `desktop_minimize` do the same and report the result.

`desktop_inspect` reads at most 200 elements of a window, so a long web page, mail list or Finder folder is cut short and reports `truncated`. Two tools reach further without input. `desktop_read` reads the window's text with a budget of 4,000 elements, 64 levels deep and 1,000 children per element, within about 18 seconds; it returns the text in tree order, one line per visual line, and names each limit that cut it short. Pass `scope`, a `snapshot_id` and an element ID from an earlier inspection of the same window, to read only that element, such as the page's web area. `desktop_inspect` takes the same `scope`: it reads the window with that larger budget and lists only the scope element and its descendants, each with `attributes.depth`. The scope element is found again by its role, depth, bounds, label, title and identifier, so it must not have moved; listed IDs belong to the new snapshot, like any inspection.

Chromium and Electron apps, such as Chrome, Edge, Slack, VS Code and Discord, build the Accessibility tree of their web content only after an assistive app asks for it. Until then a web view lists few or no elements. So before `desktop_inspect`, `desktop_read` or a `desktop_wait` element or text poll reads an app whose bundle ships an Electron, Chromium Embedded or Chromium framework, the host sets `AXManualAccessibility` on that app. It also does so after a read that finds a web area with at most one element under it, and then reads the window once more. It waits half a second after turning it on, so the page can build its tree. The host sets it at most once per launch of the app, and it stays on until the app quits, since VoiceOver or another assistive app may rely on it too. It never sets `AXEnhancedUserInterface`, which changes how some apps animate and place their windows. The result reports `web_accessibility`:
- **`enabled`**: this read turned it on.
- **`already_on`**: it was already on, from an earlier read or another assistive app.
- **`unsupported`**: the app doesn't accept it, and nothing changed.
- **`unknown`**: the request failed or wasn't confirmed; the read went ahead with the tree as it was.

Pass `web_accessibility: false`, to any of the three, to leave the app as it is; its web content may then be missing. Turning it on sends no input, so it runs while input is paused, and the app's activity list shows it once per app launch as **Turn on web accessibility**. A table read uses the tree as an earlier inspection left it.

`desktop_read` with `table: true` reads a table instead of text. Its `scope` is a table, outline or grid from an accessibility inspection, such as a Finder list, a Mail message list, a Numbers table or a web table, or an area that holds one, such as the scroll area or web area; the first table in it is read, and `tables_in_scope` counts the others. It reads Accessibility alone, with `desktop_read`'s budget and no screenshot, and returns:

- `columns`: the header titles in order. They come from the table's columns, from the header buttons a scroll view draws just above the table, or from a web table's header row; `null` when there are none. Scope the scroll area rather than the table when a list's headers are missing.
- `rows`, each with its `cells` (the Accessibility text of each cell, in column order), its `element` ID for `desktop_click`, and `selected`. Outline rows, as in Finder's list view, also give `depth` (0 at the top level) and `expanded`.
- `row_count`, every row the table exposed, and `row_offset`, where this page starts.

Row IDs belong to the scope snapshot: a row gets one only when that snapshot stored it unchanged, found again by role, depth, bounds and text. A whole-window inspection stores only its first 200 elements, so for a long table inspect again with `scope` set to the table, then read the table with that snapshot. A row scrolled out of view has an ID but must be scrolled into view before a click. Pages hold `max_rows` rows, 100 by default and 500 at most; pass `row_offset` for the next page. Cells are cut to 256 characters, rows to 64 cells, and a page to 96 KB of cell text, each reported in `truncation` with the traversal's own limits. Tables that load rows as they scroll, such as long web grids, expose only the loaded rows.

`desktop_set_cell` writes one cell of a table that `desktop_read` read. Pass the read's `pid`, `window`, scope snapshot as `snapshot` and scope element as `table`, the row's element ID as `row`, and `column` as an exact column title or a 0-based index. The host reads the table again and writes the cell's first editable control:

- A text field, text area or combo box goes through `desktop_type`. In a web grid, that means the field must have keyboard focus, as for any web field: click the cell, inspect, read the table with that snapshot, then write.
- A checkbox, slider, stepper or date picker goes through `desktop_set_value`.

It then reads the table once more with the same snapshot, which a write consumes for input but not for reading, and compares the cell at the same row position and column. The result is `completed` only when the control reads back the value and the row's other cells are unchanged. Otherwise it is `unknown`, and `cell.readback` says why: `differs` when the app reformatted or rejected the value, `row_changed` when another row now sits there, as when Finder re-sorts after a rename, and `unreadable`. A cell that shows only text has no control and is refused before any input; spreadsheets edit cells in place instead (see [recipes](recipes.md#edit-a-spreadsheet-cell)). Not yet checked on a live system: Finder renames, a web grid, and whether Numbers or Excel cells expose controls.

With `ocr: true`, `desktop_inspect` (in either mode) and `desktop_screen` also run Apple Vision text recognition, at its accurate level and on this Mac, on the screenshot they captured. `recognized_text` lists up to 300 lines in reading order, top to bottom and left to right, with confidence and a box as fractions of the screenshot from its top-left corner; `desktop_screen` adds bounds in global desktop points. A box's center is a pointer point for that inspection's snapshot. Recognition is limited to 8 seconds; the first one after a restart can take longer while Vision loads its model. Recognized text comes from pixels, so it can misread or miss text, and is labeled as such.

`desktop_screen` and `desktop_inspect` save their capture when given `save_path`, an absolute `.png` path in an existing folder. The file is the full-resolution PNG the host captured, never scaled down as the returned image is, and the result's `saved` gives its `path` and pixel `width` and `height`. An existing file is refused before anything is captured unless `overwrite` is true, and a symlink or folder is never replaced. `region`, in global top-left desktop points as window and display bounds use, saves only that part of the capture, mapped at the capture's own pixel scale; it must lie inside the captured display or window, and the returned image stays whole so pointer fractions still match it.

`desktop_clipboard_read` with `format: "image"` returns a preview of at most 1,600 pixels and 900 KB. To keep the image itself, pass `save_path`: the host writes the clipboard's original PNG, JPEG or TIFF bytes there unchanged, up to 10 MiB, and `saved` gives the `path`, `uti`, `mime_type`, `bytes`, `width` and `height`. The extension must name the image's type (`.png`, `.jpg` or `.jpeg`, `.tif` or `.tiff`); otherwise nothing is written and the refusal names the type to use. `overwrite` and the folder, file and symlink rules work as for captures. The original is read under the same clipboard-read permission as the preview, and with no image on the clipboard nothing is written.

`desktop_dialog_answer` with `path` chooses an absolute path in an Open or Save panel without pressing its default button. An existing folder becomes the panel's folder. Any other path names a file in an existing folder: a Save panel takes its folder and file name, and an Open panel selects it. Unlike buttons and fields, this is foreground input: the host activates the panel's app, checks that the exact panel has keyboard focus before each key, and uses the panel's path field or Go to Folder. The result is `completed` only when the panel reads back the folder and, in a Save panel, the name. Choosing a file in an Open panel, or a panel that shows no folder, is `unknown`; list the dialog before pressing its default button.

`desktop_insert` pastes into the focused control the snapshot reports, and restores the clipboard once it reads the edit back. When the snapshot reports no focused control, as in terminals, canvases, custom views and many web editors, it types the text into whatever has keyboard focus in that window instead, with the same check `desktop_key` makes before each character: the app's focused element must still be inside the window, and the window must be the app's key window. Pass `route: "type"` to type into an observed control whose text can't be read, such as a terminal's text area, or `route: "paste"` to refuse typing. Typing doesn't touch the clipboard, takes at most 1,000 UTF-16 code units, and refuses newlines, tabs and other control characters, because typing them presses Return or Tab; press those with `desktop_key` where you mean to. It is refused while secure keyboard entry is on, as for a password field or Terminal's Secure Keyboard Entry. A typed insertion is `unknown` unless the host reads back an observed control's new value, so inspect the window before acting again.

`desktop_type` sets a native field's value through Accessibility. Browsers accept that write for a field in a web page without firing the page's `input` and `change` events, so React and similar forms keep their old state. The host checks each text field's ancestry before writing, and a field inside a web area, or one whose ancestry it can't read, is never written that way. Instead, when that field is the snapshot's keyboard focus, `desktop_type` selects its text and types the replacement with key events sent to the app in the background, then reads the field back: the result is `completed` when the text matches and `unknown` otherwise. A web field without focus is refused before any input, with a hint to click it and inspect again; a click is a page action, so it is never done implicitly. Typed text is limited as for typed insertion, 1000 UTF-16 code units with no control characters.

A secure text field, such as a password field, reports the role `AXTextField` with `attributes.subrole: "AXSecureTextField"`. Its value is never read: Accessibility gives only one mask character per typed character, and even that is left out of inspections, reads and waits. `desktop_type`, `desktop_set_value` and `desktop_select` refuse a secure field before any input, with `SECURE_FIELD_REQUIRES_FILL`. While a secure field has keyboard focus, `desktop_key` refuses keys that type characters and Command-V, and `desktop_insert` refuses every route, with the same code and nothing sent. Return, Tab, Escape, arrows, Delete and other shortcuts still work.

`desktop_fill_password` is the only way to put characters into a secure field. Pass the snapshot and the field's element ID; the field must be the snapshot's keyboard focus, so click it and inspect again first if it isn't. Then name the password in one of two ways:
- **A Keychain item (preferred).** `service` names a generic password and `server` an internet password, with `account` when more than one matches. Desktop Tools reads the item itself, so macOS asks the user before each read and the agent never sees the password. An internet password fills only a field in a web page whose URL host is its server.
- **Text.** The user approves each fill in a Desktop Tools prompt naming the agent, the app and the site, unless they turned on Always Allow Agent-Supplied Passwords in the menu. While that prompt is open, agent input is refused with `SELF_TARGET_REFUSED`.

The host replaces the field's contents with key events. The fill is completed when the field then shows only mask characters, exactly as many as the password has; otherwise it is `unknown`. Results and Recent Activity record that a fill happened and where, never the password or its length. A fill refused by the user, by the Keychain, or after a minute without an answer sends nothing. System password prompts, such as the administrator prompt (SecurityAgent), are refused. Touch ID isn't supported.

Some ways to paste remain outside these checks: choosing Paste from a menu with `desktop_menu`, clicking Paste in a context menu, and dragging text onto the field.

`desktop_insert` also pastes an image or files into a native text area, such as TextEdit's rich text, Mail or Notes, in place of text; see [the details](#details-by-tool) for how it confirms the paste and when it refuses.

`desktop_select` sets a field's `AXSelectedTextRange` and reads it back. Text in a web page has no such range, so for an element inside a web area, such as a paragraph, heading or link, the host uses WebKit's text markers instead. It finds the requested range from the element's own start, sets the web area's selected marker range, and reads it back: the result is `completed` only when the selection covers exactly the requested text, and `unknown` otherwise. A long element may need the host to walk the text one marker at a time; that walk stops after 2,048 steps or 300 ms, and the selection is refused before anything is selected, with a hint to select within a smaller element. Offsets are UTF-16 units within the element, as for fields. To copy the selection, press `c` with `command` through `desktop_key`, then `desktop_clipboard_read`. Not yet checked on a live system: selectable text outside web pages that isn't a field, such as a read-only native text view, which works only if it exposes a settable `AXSelectedTextRange` and is refused otherwise; and text in a PDF, as in Preview.

`desktop_inspect` lists the actions each element offers in `attributes.actions`. A pop-up button has no settable value: click it, then pick the item from the next observation, which puts an open menu's items first.

`desktop_system_key` is for shortcuts that belong to macOS rather than a window: Spotlight (Command-Space), the app switcher (Command-Tab), Mission Control (Control-Up), the screenshot tools (Command-Shift-4 and 5) and the next input source (Control-Space; `desktop_input_source` selects a specific one and reads it back). It takes the same keys and modifiers as `desktop_key`, but no snapshot. The keys are posted as ordinary keyboard input, so they reach whatever is frontmost, and they often move focus, activate an app or open system UI. Nothing reads back what a shortcut did, so the result is `unknown` even after delivery; observe with `desktop_screen`, `desktop_apps` or `desktop_windows`. Any chord with Command and W, Q, H or M is refused before anything is sent, including Command-Shift-Q (log out).

`desktop_system_key` also presses the media, volume and brightness keys: `play_pause`, `next_track`, `previous_track`, `volume_up`, `volume_down`, `mute`, `brightness_up`, `brightness_down`, `keyboard_brightness_up` and `keyboard_brightness_down`. They take no modifiers. These keys have no key code; they are posted as the system-defined events the keyboard sends, so macOS acts on them rather than a window. Media keys go to whichever app macOS routes them to, usually the one playing, and the brightness keys change the main display and the keyboard backlight where macOS supports it. The result is `unknown` after delivery, because nothing reads back the volume, brightness or playback state. Don't blindly repeat `play_pause` or `mute`; they toggle.

`desktop_input_source` lists the enabled keyboard input sources that can be selected, as the input menu shows them. Each source has an `id`, `name`, `kind` (`keyboard_layout`, `input_mode` for one mode of an input method such as Hiragana, or `input_method`), its first 8 `languages` and whether it is selected. The result also gives `current` and the `keyboard_layout` that `desktop_key` maps characters through.

With `select` set to a listed `id`, the host selects that source with Text Input Sources (`TISSelectInputSource`), with no keys pressed, and the client then reads the current source back for up to a second:
- **`completed`** means the source reads back as selected, with `before` and `current`.
- **Already selected:** the result is `completed` with `changed: false`, and nothing is changed.
- **Not enabled:** the request is refused.
- **Locked session:** the request is refused.
- **Input paused** in the app: the request is refused, and nothing is changed.
- **macOS refuses the selection:** if the source still reads back unchanged, the result is `refused`.
- **No readback:** the result is `unknown`.

Listing runs in the client process and needs no permission. Selecting goes through the host like other input, so the app's pause and activity list cover it; it needs no Accessibility either. The switch applies to every app until it is changed again. An input method's new mode may reach the frontmost app only after its next focus change.

`desktop_notifications` inspects Notification Center's windows on screen: its banners and alerts, and its panel when open (click the clock with `desktop_menubar_click` to open it). Each notification has an `id`, its app, title, subtitle, body and time where they can be read, its raw `texts` and `description`, and its `actions`: `open`, plus the custom actions Notification Center lists for it by exact name, such as Close, Show, Options or the posting app's own. `desktop_notification_action` takes that `id` and one of those actions. `open` is the notification's default click (on a stack, it expands the group); `close` runs Close; any other name runs that one listed custom action through Accessibility. Only Notification Center's elements list or run custom actions, at most 8 per element, each one line of at most 64 characters, and a name listed twice is never offered. A notification that has gone or changed is refused before input. Afterwards the notifications are read again: the result is `completed` only when the notification is gone, and `unknown` otherwise. System alerts such as permission prompts are dialogs, so `desktop_notifications` lists them under `system_alerts` for `desktop_dialog` and `desktop_dialog_answer` and never acts on them. This is built against the Notification Center structure of macOS 11 to 15.

An action refused because its window was minimized after inspection reports `WINDOW_MINIMIZED`, with the low-level reason as its `cause`. Restore the window with `desktop_restore`, then inspect it again.

## Details by tool

These are the rest of each tool's contract, beyond its description.

**`desktop_clipboard_read`.**
- **Text.** It returns the complete text, up to a 24 KB JSON result. An empty string is distinct from absent text (`present: false`).
- **Image.** The preview is oriented, with separate source and preview metadata. A large preview may flatten transparency onto a white JPEG.
- **Files.** It returns up to 32 advertised local file URLs and their decoded paths. It neither opens the files nor confirms they exist.
- **Refused.** Text and image reads need exactly one clipboard item. File promises, legacy-only filename lists, items mixing files with other content, and unreadable or oversized content are refused.
- **Side effects.** It needs macOS to allow clipboard reading. It never changes the clipboard or releases a pending paste reservation.

**`desktop_clipboard_write`.**
- **Image.** Its original bytes, orientation and transparency are kept. It may be at most 10 MiB and 64 million pixels.
- **Files.** Each path must be an existing file, folder or symbolic link. The check reads only metadata, not contents, and doesn't resolve links. References keep their order and duplicates within the 24 KB read-result limit. `file_count` counts the references requested, not what a receiver copies or pastes.
- **Persistence.** The write lasts until the next copy or write.

**`desktop_launch` and `desktop_open`.**
- **Choosing a copy.** A bundle ID lets macOS choose the installation; a path selects one copy. One launch can include several counted activation attempts.
- **`desktop_open` limits.** Items are at most 4096 UTF-16 units, and the whole request at most 16 KiB. Paths keep Unicode and spaces, with no shell expansion. URLs must already be encoded and are never repaired. Any scheme, including `file` and custom schemes, has its receiving app's normal effects.
- **Neither tool** batches items, creates extra instances or handles dialogs.

**`desktop_menus` and `desktop_menu`.**
- **Reading.** A read is bound to the same process generation before and after. Native results can come from a 2-second cache, so their time and completeness, including lazy or budget-limited submenus, are unknown. Result truncation is counted separately (`truncated`, `omitted`). Enabled and checked state are left out, because the native service substitutes defaults for attributes it can't read. Paths are for discovery, not reusable action targets. Accessibility reads are synchronous and can delay cancellation.
- **Running a command.** `desktop_menu` resolves the path afresh. It refuses missing, ambiguous, disabled or unavailable lazy paths, and presses only the final item once. Its reads and the press run off the GUI actor, with a finite messaging timeout. Cancellation waits for the native call to return and can't undo delivered input.

**`desktop_menubar_click`.** Before pressing, the host lists the menu bar again. It refuses if the item at that index no longer has the same owner generation, identifier, title, bounds or neighbours. Where an item has its own window, it is clicked through that window. The result lists the windows that appeared within about a second, front to back, with pid, window ID, owner, layer and bounds. It captures their region as an image without a snapshot.

**`desktop_dock`.** Titles match exactly, including case, punctuation and Unicode. The right-click menu's submenus can't be reached.

**`desktop_quit` and `desktop_close`.** A normal quit or close can open an unsaved-work dialog. The result is then `unknown`, with fresh inventory when available. The host never retries, force-closes or answers the dialog. `force: true` terminates that exact process immediately, with no save prompt.

**`desktop_inspect`.**
- **Accessibility mode** (the default) can return an action snapshot with element IDs.
- **Pixels mode** returns a snapshot with no element IDs and no focused control. It authorizes only point clicks, point scrolls and drags in that exact window.
- **After an action,** the automatic observation uses accessibility mode. If it fails, inspect again with pixels mode.
- **In a Chromium or Electron app,** it first turns on the app's web accessibility, once per launch, unless `web_accessibility` is false. The result's `web_accessibility` says what happened; see [Input](#input).

**`desktop_click`.** A single left click on a supported editable text field, by element or point, also requests keyboard focus. The result says whether focus was verified; use `desktop_select` to choose a range or caret position. Points stay bound to the captured window, even when the returned screenshot was scaled.

**`desktop_scroll`.** `amount` is in native scroll units. Their distance depends on the route the target supports, not on pixels.

**`desktop_set_value`.**
- **Dates.** A date is written as the control's date value and must read back to the second. The result shows it in UTC. A control that drops the time or seconds reports `unknown`. If a date control refuses, the result's `keyboard_route` explains entering it field by field.
- **Toggles.** A toggle whose value is read-only but which advertises `AXPress` gets at most one press, and none when it already has the requested state.
- **Pop-up buttons.** To pick an item, use `desktop_element_action` with `AXPick`, or `desktop_click`, on the item from the fresh observation.

**`desktop_insert`, paste route.**
- **Requirements.** The field's text and selection must be readable, and macOS must allow clipboard reading so the earlier contents can be restored. The original and resulting values must each fit 65,536 UTF-16 units.
- **Delivery.** The paste is bound to the exact process, window and focused control. An exact receiver in the active frontmost app gets the paste chord directly. Any other target first gets a guarded click on a blank part of its title bar, which keeps the editor and selection; unsupported window chrome is refused. The route never changes after input begins, and the app isn't brought forward.
- **Clipboard.** The clipboard is restored only after a meaningful observed edit. After uncertain delivery, the replacement may stay on the clipboard, and anything copied since is kept. The result reports delivery separately from `consumption`, `clipboard_cleanup` and `clipboard_ownership`.
- **Reservation.** A reserved ownership refuses later automated clipboard writes until the edit is verified or the receiving process exits. Restarting the host doesn't clear it.

**`desktop_insert`, images and files.**
- **Input.** Pass `format: "image"` with one absolute `path` to a PNG, JPEG or TIFF file (at most 10 MiB and 64 million pixels), or `format: "files"` with 1 to 32 absolute `paths`, instead of `text`. Nothing is typed.
- **Receivers.** By default (`clipboard: "restore"`) the paste goes only into a native text area, which shows each attachment in its text as one U+FFFC character. Other receivers, including web content, Electron apps and single-line fields, can never show the attachment, so they are refused before input with `PASTE_UNVERIFIABLE_RECEIVER`.
- **Confirmation.** The result is `completed` when the text reads back with one such character per item in place of the selection and the caret after them, and the prior clipboard is then restored, as for text. `attachment_evidence` is `attachment_attribute` when the receiver also marks those characters as attachments, otherwise `replacement_characters`.
- **Reservation.** Until the paste is seen, the same reservation as a text paste holds, so a receiver that ignores it, such as a plain-text document, keeps the clipboard reserved until the edit appears or the app quits.
- **Replacing the clipboard.** `clipboard: "replace"` pastes into any receiver: the prior clipboard is not kept and no reservation is taken, `clipboard_cleanup` is `left_replaced`, and the pasted item stays on the clipboard. That result is `unknown` unless the attachment is seen, and a Command-V the app hasn't handled yet pastes whatever the clipboard holds then, so inspect the receiver before the next clipboard write.
- **Finder.** `format: "files"` into a Finder window copies the files into the folder it shows, as Command-V does there. The snapshot's focus must be the window's file list, not a name being edited or the search field. Before input, the host reads the folder from the window's `AXDocument` or `AXURL`, and refuses with `PASTE_NAME_EXISTS` if any pasted name is already there, or if two files share a name, since Finder would ask whether to replace or keep both. It checks again just before Command-V. The paste is seen when every name is in the folder, read from the filesystem by the host within 5 seconds: the result is then `completed`, with the `folder` and `copy: "started"`, and the clipboard is restored. Finder may still be copying large files' contents, so wait for them before using them. A window that doesn't report its folder is refused. The paste goes to the window's own folder; in column view that is the folder whose name the window shows.

## Not supported

- **Confirmed insertion outside text fields.** Where `desktop_insert` can't observe a text control with a readable selection, such as terminals, canvases and custom views, it types the text instead, and the result is `unknown`, because nothing can read back what the receiver did with it. Typed insertion can't contain newlines or tabs.
- **Confirmed drops between windows.** A drag into another window or app, or any drag with modifier keys, is always reported as `unknown`, because nothing can confirm the drop. A path can't cross into another window: a drag between windows is one straight line.
- **Moving a window to another Space.** Since macOS 14.5 only the Dock can move windows between Spaces, so there is no tool for it. To do it by hand, open Mission Control with `desktop_system_key` (`control`, `up`), inspect it, and drag the window onto the other Space with a foreground `desktop_drag`. The result is `unknown`; check with `desktop_spaces`.
- **Pinch and rotate gestures.** Magnify and rotate trackpad gestures can be posted only through undocumented event fields. Even then they reach some apps but not others, such as Chrome. Use the app's zoom and rotate menu items or their shortcuts instead; see [Zoom or rotate instead of pinching](recipes.md#zoom-or-rotate-instead-of-pinching).
- **Automatic retries.** By design, nothing is retried. After a `refused` or `unknown` result, observe again before deciding whether to act.
- **Remote Macs.** The tools act on the Mac running the host app, on macOS 15 or later.

Open bugs and gaps are tracked in [issues](https://github.com/githubnext/desktop-tools/issues).
