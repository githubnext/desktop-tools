# Embed

1. Copy `libDesktopTools.dylib` and `desktop-tools-client` from a [native build](build.md) into the app bundle, and ship `Licenses/`.
2. Sign the library, the client, and the app with the same Apple Development or Developer ID team. Sign the client with an exact identifier, for example `codesign --identifier <app-id>.desktop-client`.
3. From the app's GUI process, load the library and call its C ABI:

| Symbol | Meaning |
| --- | --- |
| `void desktop_tools_start(const char *socket, const char *client)` | Serve the Bridge on `socket` for the exact signed `client` identifier from this app's team |
| `char *desktop_tools_status(void)` | JSON `{ state, error?, accessibility, screenRecording, eventSynthesizing, clipboardRead, cursor, highlight, paused }`; free with `desktop_tools_free` |
| `void desktop_tools_check(void)` | Check now that the socket is still published: publish it again if it was removed or replaced, and retry a failed start at once. The runtime also watches the socket on its own. Call this when the app is opened again (`applicationShouldHandleReopen`), since the client opens its containing app when it finds no host serving |
| `void desktop_tools_stop(void)` | Drain native operations and stop; poll status until `stopped` |
| `void desktop_tools_permission(const char *kind)` | Request `accessibility`, `screenRecording`, or `eventSynthesizing` |
| `void desktop_tools_set_cursor(bool)` | Show the agent cursor for pointer input; it is off until turned on |
| `void desktop_tools_set_highlight(bool)` | Outline and label the window the agent is using; it is off until turned on |
| `void desktop_tools_set_paused(bool)` | Pause all input: refuse every operation that changes the desktop, and clipboard writes, before dispatch, while reads continue. It starts resumed, is held in memory only, and only the embedding app can change it |
| `void desktop_tools_set_caller_handler(void (*)(const char *))` | Ask the user before serving each agent. Once set, every request, observation included, is refused with `CALLER_NOT_APPROVED` unless its caller is allowed, and the handler gets the JSON caller `{ key, name, path, team?, identifier?, signer? }` the first time an unknown one asks, on a background thread; the request is refused at once, never held. Agent input that targets the app's bundle family, or arrives while one of its prompts or menus is open, is refused with `SELF_TARGET_REFUSED`. Without a handler every caller is served, as before. Pass NULL to turn it off |
| `void desktop_tools_set_callers(const char *)` | Every answer so far, as a JSON array of `{ caller, allowed, decided }`; call it at start and after each answer. An answered caller is never asked about again |
| `char *desktop_tools_activity(void)` | JSON array of the last 20 operations, newest first: `{ time, agent, pid, operation, app?, window?, outcome, count }`; free with `desktop_tools_free`. With a caller handler, `agent` and `pid` name the verified caller |
| `void desktop_tools_set_log(const char *path)` | Append each operation listed by `desktop_tools_activity` to `path`, one line each, created readable only by the user; past 1 MiB it moves to `<path>.1`. Pass NULL to stop |
| `void desktop_tools_log(const char *message)` | Append one line of the app's own to that log, such as when the user pauses input |
| `void desktop_tools_free(void *)` | Release a status or activity string |

macOS grants Accessibility, Screen Recording, and event synthesis to the embedding app. Each embedding app needs its own grants on each machine. Clients must be signed by the host's team with the exact allowlisted identifier, and the client verifies the host's team. The agent cursor and window outline draw click-through panels from the GUI process, so turn them on only from an app with a running AppKit main loop. The outline's label names the agent from `DESKTOP_TOOLS_AGENT` in the requesting client's environment, which `createDesktop` sets from its `agent` option; without it the label says "Agent". For agents outside an embedding app, use the [Desktop Tools app](app.md).

The caller is the client's nearest ancestor that isn't `node`, `npx`, `npm`, a shell, `login` or `env`, such as Claude Code or the terminal app an agent runs in. Its key is the team ID and signing identifier of its running code when that signature validates, so an update that moves it keeps its approval; otherwise it is its path, plus its identifier when it has one. Its name is its app's name, else the last part of a team-signed identifier (`claude-code`), else its file name. The process can't choose either one through its arguments or environment.
