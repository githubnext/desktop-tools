# Tools

The [MCP server](mcp.md) and `desktopTools()` expose 33 tools, one per protocol operation. Each tool's description and argument schema in `src/tools.ts` is the full contract; this page is the map.

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

A status item is pressed through Accessibility in its owner process without moving the pointer. Control Center, Notification Center and many popovers open as windows that `desktop_inspect` can read and drive; an app's plain status menu shows only in the click's capture. The Dock right-click is a real mouse event that moves the physical pointer.

## Input

| Tool | Does |
| --- | --- |
| `desktop_click` | Single, double, right, middle or triple click on an element or a screenshot point |
| `desktop_scroll` | Scroll an element or point up, down, left or right |
| `desktop_drag` | Press, move in a straight line, and release inside one window |
| `desktop_type` | Replace an editable field's whole value |
| `desktop_select` | Select literal text in a field, or put the caret before or after it |
| `desktop_insert` | Insert text at the caret or over the selection with one temporary paste, then restore the clipboard |
| `desktop_key` | Press one key with optional Command, Control, Option and Shift |
| `desktop_menu` | Run one menu command by its exact title path |
| `desktop_dialog_answer` | Press one dialog button by its exact title, or replace one dialog text field's value |
| `desktop_clipboard_write` | Replace the clipboard with text, an image, or file references |

Pointer input is delivered to the exact window without moving the physical pointer. When the host turns on the agent cursor, an orange arrow first glides to each click, scroll or drag point, about a third of a second before the input is sent. It then shows a ripple for clicks, chevrons for scrolls and a trail for drags, and fades after a few seconds idle. The cursor never takes clicks or focus and is left out of `desktop_inspect` and `desktop_screen` captures. It is decoration only: if it fails or is slow, input proceeds unchanged after at most 600 ms. Keyboard input, `desktop_type` and `desktop_select` don't show it.

## Not supported

- **Keys outside text fields.** `desktop_key` and `desktop_insert` need a focused text control, so Escape, arrows, Return and shortcuts in lists, the Finder or canvases are refused ([#13](https://github.com/githubnext/desktop-tools/issues/13)).
- **Punctuation and other keys.** Keys are letters, digits, F1–F12, Return, Tab, Escape, Space, Backspace, Delete, arrows, Home, End, Page Up and Page Down. Shortcuts such as Command-comma can't be sent; use `desktop_menu` for menu commands.
- **Hover, pointer moves and press-and-hold.** Drags are one straight line within one window; there is no drag between windows or apps.
- **Choosing paths in file panels.** `desktop_dialog_answer` can type a file name into a save panel's field, but it can't navigate an open or save panel to a folder.
- **Automatic retries.** By design, nothing is retried. After a `refused` or `unknown` result, observe again before deciding whether to act.
- **Remote Macs.** The tools act on the Mac running the host app, on macOS 15 or later.

Open bugs and gaps are tracked in [issues](https://github.com/githubnext/desktop-tools/issues).
