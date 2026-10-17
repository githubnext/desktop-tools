# Embed

1. Copy `libDesktopTools.dylib` and `desktop-tools-client` from a [native build](build.md) into the app bundle, and ship `Licenses/`.
2. Sign the library, the client, and the app with the same Apple Development or Developer ID team. Sign the client with an exact identifier, for example `codesign --identifier <app-id>.desktop-client`.
3. From the app's GUI process, load the library and call its C ABI:

| Symbol | Meaning |
| --- | --- |
| `void desktop_tools_start(const char *socket, const char *client)` | Serve the Bridge on `socket` for the exact signed `client` identifier from this app's team |
| `char *desktop_tools_status(void)` | JSON `{ state, error?, accessibility, screenRecording, eventSynthesizing, clipboardRead, cursor }`; free with `desktop_tools_free` |
| `void desktop_tools_stop(void)` | Drain native operations and stop; poll status until `stopped` |
| `void desktop_tools_permission(const char *kind)` | Request `accessibility`, `screenRecording`, or `eventSynthesizing` |
| `void desktop_tools_set_cursor(bool)` | Show the agent cursor for pointer input; it is off until turned on |
| `void desktop_tools_free(void *)` | Release a status string |

macOS grants Accessibility, Screen Recording, and event synthesis to the embedding app. Each embedding app needs its own grants on each machine. Clients must be signed by the host's team with the exact allowlisted identifier, and the client verifies the host's team. The agent cursor draws click-through panels from the GUI process, so call `desktop_tools_set_cursor(true)` only from an app with a running AppKit main loop. For agents outside an embedding app, use the [Desktop Tools app](app.md).
