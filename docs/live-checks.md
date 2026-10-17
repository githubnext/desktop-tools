# Live checks

The live checks in [#42](https://github.com/githubnext/desktop-tools/issues/42) need an unlocked Mac. `npm run live-check` runs the ones that can be automated, through the same MCP server (`dist/mcp.js`) and host that agents use:

```sh
npm run live-check                    # the installed app
DESKTOP_TOOLS_STATE=/tmp/dev npm run live-check -- --only 82,88
npm run live-check -- --list          # list the checks without running them
npm run live-check -- --json /tmp/live.json
```

It drives the installed Desktop Tools, or the dev app whose state folder `DESKTOP_TOOLS_STATE` names. Each check prints `PASS`, `FAIL` or `SKIP` with its evidence, and a summary groups them by PR. The exit status is 1 when any check fails, and 2 when nothing could run.

What it touches:

- It refuses to start while the screen is locked, the session is off the console, the screensaver runs or the displays sleep.
- It makes its own fixtures in a new `/tmp/desktop-tools-live-*` folder: a plain and a rich TextEdit document, a Finder folder of eight files and a subfolder, a PNG, and a web page with a React-style controlled input, a date input, a contenteditable, a table with `<th>` headers and a grid of inputs. The folder is removed at the end unless `--keep-fixtures` is passed.
- It opens those fixtures in TextEdit, Finder and Safari with `desktop_open`, and acts only on the new windows. At the end, even after a failure or Control-C, it closes each window it opened and quits only the apps it launched itself. A fixture document that asks to save is answered with Delete or Don't Save, on that document only.
- Web checks are skipped while Safari has windows open, since a fixture page could open as a tab in one of them.
- Clipboard checks run only when the clipboard holds plain text, and that text is written back at the end. The input-source check selects another enabled keyboard layout, then the original again.
- Modifier clicks (#77) and `desktop_system_key` (#89) use the real keyboard and pointer, as they always do; nothing else needs the foreground.

## Still manual

These stay manual, because they are destructive, change system settings, need a second display, Space or password, or need an app or account the harness can't create:

- **#80 media, volume and brightness keys:** they change the output volume, playback and display brightness system-wide, and each delivered key is `unknown`.
- **#43 window outline:** what the outline looks like, during a Space switch, on a full-screen window and while dragging; the menu toggle; clicks through the margin and label.
- **#78 full screen, #66 Spaces and #1 `other_space`:** each needs a second Space.
- **#2 two displays:** negative-origin displays, rearranging a display between inspect and click, and SIGKILL of a client mid-drag.
- **#3 clipboard lifecycle:** SIGKILL of the MCP client during an insert, and quitting Desktop Tools after an uncertain insert.
- **#99 wedge and permission cases:** an image into a plain-text TextEdit document (holds the clipboard until TextEdit quits), `clipboard: "replace"` into Slack or a browser, Mail and Notes, a 10 MiB TIFF, and clipboard read access set to Ask.
- **#100 Pause All Input and #98 Recent Activity:** both are read and toggled in the app's menu.
- **#74 notifications:** they need banners from a real app, and closing or opening one acts on it.
- **#41 Dock and status menus:** the Dock right-click moves the pointer, and a third-party status menu belongs to the user.
- **#57, #4 and #9 Open and Save panels:** a Save sheet can write files outside the fixtures if answered wrongly.
- **#64 modifier drags:** Option-drag in Finder copies files and Command-drag moves them.
- **#90 input methods:** typing in an input method's mode, such as Japanese Hiragana, needs that method enabled.
- **#86 and #92 in other apps:** Numbers, Excel, Mail and Chrome, and a long Finder folder of 300 or more files.
- **#88 in other apps:** Chrome, read-only native text views and Preview PDFs.
- **#27 Codex:** adding the server to Codex's configuration.
- Anything that asks for a password or an administrator's approval.
