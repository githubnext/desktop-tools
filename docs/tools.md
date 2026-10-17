# Tools

The [MCP server](mcp.md) and `desktopTools()` expose 45 tools, one per protocol operation. Each tool's description and argument schema in `src/tools.ts` is the full contract; this page is the map.

Targets are exact: an app target binds a process generation, and a window target binds its window ID and bounds. Input acts on a single-use snapshot from the latest `desktop_inspect`. A stale or changed target is refused rather than redirected. Action results report `completed`, `refused`, or `unknown`, and nothing is retried automatically.

## Find and observe

| Tool | Does |
| --- | --- |
| `desktop_apps` | List running apps, optionally filtered by name or bundle ID |
| `desktop_windows` | List one app's windows, each with whether it can be observed and acted on now, and why not |
| `desktop_inspect` | Read one window's Accessibility elements and a screenshot, or only pixels when Accessibility is unavailable; returns the snapshot that input uses. `scope` lists one element's subtree from a much larger read, and `ocr` adds recognized text |
| `desktop_read` | Read the text of one window, or of one inspected element's subtree, through Accessibility, up to 96 KB including content scrolled out of view; read only, with no snapshot |
| `desktop_wait` | Wait, up to 45 seconds, until a window, dialog, element, text or app condition holds, then return what matched; read only |
| `desktop_screen` | Capture one whole display and list the displays and the windows on it, front to back; observation only, with no input snapshot. `ocr` adds recognized text |
| `desktop_menus` | Read an app's menu bar structure without opening it |
| `desktop_dialog` | Read the open dialog or sheet in an app or window: its buttons, text fields and labels |
| `desktop_clipboard_read` | Read the clipboard as text, an image, or file references |

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

When `desktop_inspect`, `desktop_read` or an action is refused, the result's `target_availability` carries the same classification, read from a fresh listing after the failure. A window that looks available but failed with an incomplete Accessibility tree, as while a web view first loads, is `sparse_accessibility`: wait a second or two and inspect once more, or use pixels mode and OCR. A window missing from the listing is `window_gone`. The classification names the likely cause; it can't prove it.

Captures go through ScreenCaptureKit, which every Peekaboo process for the user shares one call at a time. When an earlier capture timed out and hasn't returned, which usually means another capture on the Mac is busy, a new capture waits up to 2 seconds for it. If it still hasn't returned, the capture is refused with a message saying the problem is temporary; wait a few seconds and inspect again. There is no fallback capture, because every other capture path would also use ScreenCaptureKit while the abandoned call still runs. `desktop_apps` has 2.5 seconds to read the app inventory and is refused, not cut short, when the Mac is too busy to finish in time.

`desktop_wait` replaces polling `desktop_inspect` or `desktop_windows` after slow work such as a launch, a page load, an export or a dialog opening. Each call waits for one condition (`until`):

- `window_appears`: an app, by `bundle_id` or `pid`, has a window that is on screen, minimized or on a Space, optionally with an exact `title` or a `title_contains` substring. `window_gone`: the window `pid` and `window` is no longer listed, or its app quit.
- `dialog_appears`, `dialog_gone`: `desktop_dialog` finds a dialog, alert or sheet in app `pid`, or in its window `window`, or finds none.
- `element_appears`, `element_gone`: an element of window `pid` and `window` matches `element`, an exact role and at least one of an exact title, value or identifier.
- `text_changes`, `text_equals`, `text_contains`: the window's text, a `scope`'s text, or the value of the one element `element` matches, differs from the first poll, equals `text` or contains it.
- `app_running`, `app_frontmost`, `app_quit`: an app, by `bundle_id` or `pid`, is running, is the active app, or no longer runs.

The wait polls with backoff, from 200 ms up to 2 seconds between polls, for `timeout_ms` (10 seconds by default, 45 at most), and returns `matched` with what matched or `timed_out` with the last observation. It sends no input and never activates an app. Each poll is a separate read, so the wait holds no lock between polls, and other agents' operations run in between. Element and text polls read the window through Accessibility only, with `desktop_read`'s budget and no screenshot, so they don't use ScreenCaptureKit. Absence is reported only when it is certain: a traversal cut short never counts as an element being gone, a partial inventory never counts as a window or app being gone, and a dialog counts as gone only when Accessibility reached every window of the app. Matched windows and apps come as `desktop_windows` and `desktop_apps` rows with their targets. When an element appears, the wait inspects the window once more (with the `scope`, if given) and returns that snapshot's ID and the matching elements' IDs, which the action tools accept; when the inspection doesn't list the element, its `snapshot_id` is null and the agent must inspect before acting.

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
| `desktop_click` | Single, double, right, middle or triple click on an element or a screenshot point |
| `desktop_scroll` | Scroll an element or point up, down, left or right |
| `desktop_drag` | Press, move in a straight line or along a path of up to 16 points, and release inside one window, or into another window or app; optionally hold modifier keys |
| `desktop_hover` | Move the real pointer over an element or point, to show tooltips and hover states |
| `desktop_press` | Press and hold an element or point for up to 10 seconds, then release in place |
| `desktop_type` | Replace an editable field's whole value; a web text field is typed into with key events so the page sees the input |
| `desktop_select` | Select literal text in a field, or put the caret before or after it |
| `desktop_set_value` | Set a slider, stepper or level indicator to a number, a checkbox, switch or disclosure triangle on or off, or a date or time picker to an ISO 8601 date, and read it back |
| `desktop_element_action` | Perform one Accessibility action an element lists, such as `AXShowMenu`, `AXIncrement`, `AXDecrement`, `AXPick` or `AXCancel` |
| `desktop_insert` | Insert text at the caret or over the selection with one temporary paste, then restore the clipboard; where no text control can be observed, type it into the window's keyboard focus |
| `desktop_key` | Press one key with optional Command, Control, Option and Shift: any character key, such as `,` or `/`, or a named key |
| `desktop_system_key` | Press one system-wide shortcut, such as Command-Space or Control-Up, on whatever is frontmost |
| `desktop_menu` | Run one menu command by its exact title path |
| `desktop_dialog_answer` | Press one dialog button by its exact title, replace one dialog text field's value, or choose a path in an Open or Save panel |
| `desktop_clipboard_write` | Replace the clipboard with text, an image, or file references |

Pointer input is delivered to the exact window without moving the physical pointer, except for `desktop_hover` and a `desktop_drag` with `to_snapshot` or `modifiers`. Hover effects follow the real pointer, so it moves the user's pointer and leaves it there. Before moving, it checks that the snapshot's window is still at the same place and frontmost at the point, and refuses otherwise. Afterward, it checks that the pointer arrived and the window is still frontmost there; if either can't be confirmed, the result is `unknown`. A drag into another window or app can't stay inside one window, so it also uses the real pointer, and pressing in the source may bring its app forward. Pass the destination's snapshot as `to_snapshot`. Both points must be uncovered at their snapshot positions, or the drag is refused before input. The pointer rests on the start point, then presses, pauses, moves, rests over the destination and releases. The result is always `unknown`; inspect both windows to see whether the drop happened. A drag with `modifiers`, such as Option to copy or Command to move in Finder, or Shift to constrain, holds the real keys system-wide from before the press until after the release, so it takes the same foreground route even within one window, and its result is `unknown` too. A `path` adds up to 16 points visited in order in straight segments; it works in both routes within one window but not with `to_snapshot`. `desktop_press` holds the button through the same exact-window route as a drag, and the host always releases it, even when the call is interrupted or the window changes. When the host turns on the agent cursor, an orange arrow first glides to each click, scroll, drag, hover or press point, about a third of a second before the input is sent. It then shows a ripple for clicks, chevrons for scrolls and a trail for drags. For a press, it stays squeezed until the button is released, then ripples. The cursor fades after a few seconds idle. The cursor never takes clicks or focus and is left out of `desktop_inspect` and `desktop_screen` captures. It is decoration only: if it fails or is slow, input proceeds unchanged after at most 600 ms. Keyboard input, `desktop_type` and `desktop_select` don't show it.

When the host turns on the window highlight, the window an inspection or action targets gets an orange outline and a label such as "Claude is using TextEdit". It shows from the moment the request reaches the host, moves to a new window when the target changes, and fades about four seconds after the last request. The outline follows the window as it moves or resizes and stays directly above it in the window order, so windows in front of the target also cover the outline. It hides while the window is minimized, off screen or on another Space. Like the cursor, it never takes clicks or focus and is left out of captures. Requests without one exact window, such as `desktop_screen`, menus or the clipboard, don't show it.

`desktop_key` goes to the control the snapshot reports as focused. When there is none, as in Finder lists, outlines, tables, canvases and many web areas, it goes to whatever has keyboard focus in that window; the result's `receiver` is `observed_control` or `window_focus`. Either way the key is sent in the background, and is refused unless the app's focused element is still inside the window, and the window is still the app's key window, before each event.

`desktop_key` takes a character key as the character it types, and finds that key on the current keyboard layout, so `,` is the comma key on any layout. A character that needs Shift or Option, such as `?` or `A`, is refused with the key and modifier to send instead (`/` with `shift` on a US layout); the key press never holds a modifier that wasn't asked for. The named keys are `enter`, `tab`, `escape`, `space`, `backspace`, `delete` (forward delete), `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `help` (Insert on PC keyboards), `f1` to `f20`, and the keypad keys `keypad0` to `keypad9`, `keypaddecimal`, `keypadplus`, `keypadminus`, `keypadmultiply`, `keypaddivide`, `keypadequals`, `keypadenter` and `keypadclear`. Dead keys, such as `´` on some layouts, can't be pressed alone; use `desktop_insert` for text. Command-W, Command-Q, Command-H and Command-M are refused before anything is sent; `desktop_close`, `desktop_quit`, `desktop_hide` and `desktop_minimize` do the same and report the result.

`desktop_inspect` reads at most 200 elements of a window, so a long web page, mail list or Finder folder is cut short and reports `truncated`. Two tools reach further without input. `desktop_read` reads the window's text with a budget of 4,000 elements, 64 levels deep and 1,000 children per element, within about 18 seconds; it returns the text in tree order, one line per visual line, and names each limit that cut it short. Pass `scope`, a `snapshot_id` and an element ID from an earlier inspection of the same window, to read only that element, such as the page's web area. `desktop_inspect` takes the same `scope`: it reads the window with that larger budget and lists only the scope element and its descendants, each with `attributes.depth`. The scope element is found again by its role, depth, bounds, label, title and identifier, so it must not have moved; listed IDs belong to the new snapshot, like any inspection.

With `ocr: true`, `desktop_inspect` (in either mode) and `desktop_screen` also run Apple Vision text recognition, at its accurate level and on this Mac, on the screenshot they captured. `recognized_text` lists up to 300 lines in reading order, top to bottom and left to right, with confidence and a box as fractions of the screenshot from its top-left corner; `desktop_screen` adds bounds in global desktop points. A box's center is a pointer point for that inspection's snapshot. Recognition is limited to 8 seconds; the first one after a restart can take longer while Vision loads its model. Recognized text comes from pixels, so it can misread or miss text, and is labeled as such.

`desktop_screen` and `desktop_inspect` save their capture when given `save_path`, an absolute `.png` path in an existing folder. The file is the full-resolution PNG the host captured, never scaled down as the returned image is, and the result's `saved` gives its `path` and pixel `width` and `height`. An existing file is refused before anything is captured unless `overwrite` is true, and a symlink or folder is never replaced. `region`, in global top-left desktop points as window and display bounds use, saves only that part of the capture, mapped at the capture's own pixel scale; it must lie inside the captured display or window, and the returned image stays whole so pointer fractions still match it.

`desktop_dialog_answer` with `path` chooses an absolute path in an Open or Save panel without pressing its default button. An existing folder becomes the panel's folder. Any other path names a file in an existing folder: a Save panel takes its folder and file name, and an Open panel selects it. Unlike buttons and fields, this is foreground input: the host activates the panel's app, checks that the exact panel has keyboard focus before each key, and uses the panel's path field or Go to Folder. The result is `completed` only when the panel reads back the folder and, in a Save panel, the name. Choosing a file in an Open panel, or a panel that shows no folder, is `unknown`; list the dialog before pressing its default button.

`desktop_insert` pastes into the focused control the snapshot reports, and restores the clipboard once it reads the edit back. When the snapshot reports no focused control, as in terminals, canvases, custom views and many web editors, it types the text into whatever has keyboard focus in that window instead, with the same check `desktop_key` makes before each character: the app's focused element must still be inside the window, and the window must be the app's key window. Pass `route: "type"` to type into an observed control whose text can't be read, such as a terminal's text area, or `route: "paste"` to refuse typing. Typing doesn't touch the clipboard, takes at most 1,000 UTF-16 code units, and refuses newlines, tabs and other control characters, because typing them presses Return or Tab; press those with `desktop_key` where you mean to. It is refused while secure keyboard entry is on, as for a password field or Terminal's Secure Keyboard Entry. A typed insertion is `unknown` unless the host reads back an observed control's new value, so inspect the window before acting again.

`desktop_type` sets a native field's value through Accessibility. Browsers accept that write for a field in a web page without firing the page's `input` and `change` events, so React and similar forms keep their old state. The host checks each text field's ancestry before writing, and a field inside a web area, or one whose ancestry it can't read, is never written that way. Instead, when that field is the snapshot's keyboard focus, `desktop_type` selects its text and types the replacement with key events sent to the app in the background, then reads the field back: the result is `completed` when the text matches and `unknown` otherwise. A web field without focus is refused before any input, with a hint to click it and inspect again; a click is a page action, so it is never done implicitly. Typed text is limited as for typed insertion, 1000 UTF-16 code units with no control characters.

`desktop_inspect` lists the actions each element offers in `attributes.actions`. A pop-up button has no settable value: click it, then pick the item from the next observation, which puts an open menu's items first.

`desktop_system_key` is for shortcuts that belong to macOS rather than a window: Spotlight (Command-Space), the app switcher (Command-Tab), Mission Control (Control-Up), the screenshot tools (Command-Shift-4 and 5) and the next input source (Control-Space). It takes the same keys and modifiers as `desktop_key`, but no snapshot. The keys are posted as ordinary keyboard input, so they reach whatever is frontmost, and they often move focus, activate an app or open system UI. Nothing reads back what a shortcut did, so the result is `unknown` even after delivery; observe with `desktop_screen`, `desktop_apps` or `desktop_windows`. Any chord with Command and W, Q, H or M is refused before anything is sent, including Command-Shift-Q (log out).

`desktop_notifications` inspects Notification Center's windows on screen: its banners and alerts, and its panel when open (click the clock with `desktop_menubar_click` to open it). Each notification has an `id`, its app, title, subtitle, body and time where they can be read, its raw `texts` and `description`, and its `actions`: `open`, plus the custom actions Notification Center lists for it by exact name, such as Close, Show, Options or the posting app's own. `desktop_notification_action` takes that `id` and one of those actions. `open` is the notification's default click (on a stack, it expands the group); `close` runs Close; any other name runs that one listed custom action through Accessibility. Only Notification Center's elements list or run custom actions, at most 8 per element, each one line of at most 64 characters, and a name listed twice is never offered. A notification that has gone or changed is refused before input. Afterwards the notifications are read again: the result is `completed` only when the notification is gone, and `unknown` otherwise. System alerts such as permission prompts are dialogs, so `desktop_notifications` lists them under `system_alerts` for `desktop_dialog` and `desktop_dialog_answer` and never acts on them. This is built against the Notification Center structure of macOS 11 to 15.

An action refused because its window was minimized after inspection reports `WINDOW_MINIMIZED`, with the low-level reason as its `cause`. Restore the window with `desktop_restore`, then inspect it again.

## Not supported

- **Confirmed insertion outside text fields.** Where `desktop_insert` can't observe a text control with a readable selection, such as terminals, canvases and custom views, it types the text instead, and the result is `unknown`, because nothing can read back what the receiver did with it. Typed insertion can't contain newlines or tabs.
- **Confirmed drops between windows.** A drag into another window or app, or any drag with modifier keys, is always reported as `unknown`, because nothing can confirm the drop. A path can't cross into another window: a drag between windows is one straight line.
- **Moving a window to another Space.** Since macOS 14.5 only the Dock can move windows between Spaces, so there is no tool for it. To do it by hand, open Mission Control with `desktop_system_key` (`control`, `up`), inspect it, and drag the window onto the other Space with a foreground `desktop_drag`. The result is `unknown`; check with `desktop_spaces`.
- **Automatic retries.** By design, nothing is retried. After a `refused` or `unknown` result, observe again before deciding whether to act.
- **Remote Macs.** The tools act on the Mac running the host app, on macOS 15 or later.

Open bugs and gaps are tracked in [issues](https://github.com/githubnext/desktop-tools/issues).
