# Tools

The [MCP server](mcp.md) and `desktopTools()` expose 35 tools, one per protocol operation. Each tool's description and argument schema in `src/tools.ts` is the full contract; this page is the map.

Targets are exact: an app target binds a process generation, and a window target binds its window ID and bounds. Input acts on a single-use snapshot from the latest `desktop_inspect`. A stale or changed target is refused rather than redirected. Action results report `completed`, `refused`, or `unknown`, and nothing is retried automatically.

## Find and observe

| Tool | Does |
| --- | --- |
| `desktop_apps` | List running apps, optionally filtered by name or bundle ID |
| `desktop_windows` | List one app's windows |
| `desktop_inspect` | Read one window's Accessibility elements and a screenshot, or only pixels when Accessibility is unavailable; returns the snapshot that input uses |
| `desktop_screen` | Capture one whole display and list the displays and the windows on it, front to back; observation only, with no input snapshot |
| `desktop_menus` | Read an app's menu bar structure without opening it |
| `desktop_dialog` | Read the open dialog or sheet in an app or window: its buttons, text fields and labels |
| `desktop_clipboard_read` | Read the clipboard as text, an image, or file references |

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
| `desktop_move`, `desktop_resize` | Set one window's origin or size in desktop points |
| `desktop_close` | Ask one window to close normally |

Window operations other than focus use background Accessibility and don't activate the app. `desktop_unhide` activates the app, because macOS has no exact background unhide.

## Menu bar and Dock

| Tool | Does |
| --- | --- |
| `desktop_menubar_items` | List the menu bar's status items left to right, with owner app, pid and process generation, identifier, title and bounds |
| `desktop_menubar_click` | Press one status item by its exact listed target, then list and capture the windows that opened |
| `desktop_dock` | List the Dock; launch or activate one item by exact title, or right-click it and choose a context-menu item by exact title |

A status item is pressed through Accessibility in its owner process without moving the pointer. Control Center, Notification Center and many popovers open as windows that `desktop_inspect` can read and drive; an app's plain status menu may show only in the click's capture. The Dock right-click is a real mouse event that moves the physical pointer.

## Input

| Tool | Does |
| --- | --- |
| `desktop_click` | Single, double, right, middle or triple click on an element or a screenshot point |
| `desktop_scroll` | Scroll an element or point up, down, left or right |
| `desktop_drag` | Press, move in a straight line, and release inside one window |
| `desktop_hover` | Move the real pointer over an element or point, to show tooltips and hover states |
| `desktop_press` | Press and hold an element or point for up to 10 seconds, then release in place |
| `desktop_type` | Replace an editable field's whole value |
| `desktop_select` | Select literal text in a field, or put the caret before or after it |
| `desktop_set_value` | Set a slider, stepper or level indicator to a number, or a checkbox, switch or disclosure triangle on or off, and read it back |
| `desktop_element_action` | Perform one Accessibility action an element lists, such as `AXShowMenu`, `AXIncrement`, `AXDecrement`, `AXPick` or `AXCancel` |
| `desktop_insert` | Insert text at the caret or over the selection with one temporary paste, then restore the clipboard |
| `desktop_key` | Press one key with optional Command, Control, Option and Shift: any character key, such as `,` or `/`, or a named key |
| `desktop_menu` | Run one menu command by its exact title path |
| `desktop_dialog_answer` | Press one dialog button by its exact title, or replace one dialog text field's value |
| `desktop_clipboard_write` | Replace the clipboard with text, an image, or file references |

Pointer input is delivered to the exact window without moving the physical pointer, except for `desktop_hover`. Hover effects follow the real pointer, so it moves the user's pointer and leaves it there. Before moving, it checks that the snapshot's window is still at the same place and frontmost at the point, and refuses otherwise. Afterward, it checks that the pointer arrived and the window is still frontmost there; if either can't be confirmed, the result is `unknown`. `desktop_press` holds the button through the same exact-window route as a drag, and the host always releases it, even when the call is interrupted or the window changes. When the host turns on the agent cursor, an orange arrow first glides to each click, scroll, drag, hover or press point, about a third of a second before the input is sent. It then shows a ripple for clicks, chevrons for scrolls and a trail for drags. For a press, it stays squeezed until the button is released, then ripples. The cursor fades after a few seconds idle. The cursor never takes clicks or focus and is left out of `desktop_inspect` and `desktop_screen` captures. It is decoration only: if it fails or is slow, input proceeds unchanged after at most 600 ms. Keyboard input, `desktop_type` and `desktop_select` don't show it.

When the host turns on the window highlight, the window an inspection or action targets gets an orange outline and a label such as "Claude is using TextEdit". It shows from the moment the request reaches the host, moves to a new window when the target changes, and fades about four seconds after the last request. The outline follows the window as it moves or resizes and stays directly above it in the window order, so windows in front of the target also cover the outline. It hides while the window is minimized, off screen or on another Space. Like the cursor, it never takes clicks or focus and is left out of captures. Requests without one exact window, such as `desktop_screen`, menus or the clipboard, don't show it.

`desktop_key` takes a character key as the character it types, and finds that key on the current keyboard layout, so `,` is the comma key on any layout. A character that needs Shift or Option, such as `?` or `A`, is refused with the key and modifier to send instead (`/` with `shift` on a US layout); the key press never holds a modifier that wasn't asked for. The named keys are `enter`, `tab`, `escape`, `space`, `backspace`, `delete` (forward delete), `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `help` (Insert on PC keyboards), `f1` to `f20`, and the keypad keys `keypad0` to `keypad9`, `keypaddecimal`, `keypadplus`, `keypadminus`, `keypadmultiply`, `keypaddivide`, `keypadequals`, `keypadenter` and `keypadclear`. Dead keys, such as `´` on some layouts, can't be pressed alone; use `desktop_insert` for text.

`desktop_inspect` lists the actions each element offers in `attributes.actions`. A pop-up button has no settable value: click it, then pick the item from the next observation, which puts an open menu's items first.

## Not supported

- **Keys outside text fields.** `desktop_key` and `desktop_insert` need a focused text control, so Escape, arrows, Return and shortcuts in lists, the Finder or canvases are refused ([#13](https://github.com/githubnext/desktop-tools/issues/13)).
- **Drags between windows.** Drags are one straight line within one window; there is no drag between windows or apps.
- **Choosing paths in file panels.** `desktop_dialog_answer` can type a file name into a save panel's field, but it can't navigate an open or save panel to a folder.
- **Automatic retries.** By design, nothing is retried. After a `refused` or `unknown` result, observe again before deciding whether to act.
- **Remote Macs.** The tools act on the Mac running the host app, on macOS 15 or later.

Open bugs and gaps are tracked in [issues](https://github.com/githubnext/desktop-tools/issues).
