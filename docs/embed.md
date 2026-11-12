# Embed

1. Copy `libDesktopTools.dylib` and `desktop-tools-client`, and optionally `desktop-tools-mcp`, from a [native build](build.md) into the app bundle, and ship `Licenses/`.
2. Sign the library, the client, and the app with the same Apple Development or Developer ID team. Sign the client with an exact identifier, for example `codesign --identifier <app-id>.desktop-client`, and the MCP server with the same one, since the host admits exactly one client identifier.
3. From the app's GUI process, load the library and call its C ABI:

| Symbol | Meaning |
| --- | --- |
| `void desktop_tools_start(const char *socket, const char *client)` | Serve the desktop tools on `socket` for the exact signed `client` identifier from this app's team |
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
| `void desktop_tools_set_password_autofill(bool)` | Fill passwords that agents supply without asking each time; Keychain items still need macOS's approval |
| `void desktop_tools_set_confirmation_handlers(ask, withdraw)` | Ask the user, on the main thread, before filling an agent-supplied password. `ask` gets an ID and JSON `{ key, title, message, allow, deny }`; `withdraw` gets the ID of a question nobody answered in time. Without them, agent-supplied passwords are refused unless always allowed |
| `void desktop_tools_answer_confirmation(uint64_t id, bool allowed)` | Answer one question from `ask`; an ID already answered or timed out is ignored |
| `void desktop_tools_free(void *)` | Release a status or activity string |

macOS grants Accessibility, Screen Recording, and event synthesis to the embedding app. Each embedding app needs its own grants on each machine. Clients must be signed by the host's team with the exact allowlisted identifier. In turn, a client signed with a team sends nothing, not even its hello, to a socket served by a process that isn't the same user's and signed by that team, and fails with `HOST_UNTRUSTED`; this covers `desktop-tools-client` and the app's `desktop-tools-mcp`. Both checks read the signature of the exact process at the other end of the socket, by its audit token. An unsigned build, such as `swift build` makes for development, skips them, as the host checks its client only when it is signed itself. The agent cursor and window outline draw click-through panels from the GUI process, so turn them on only from an app with a running AppKit main loop. The outline's label names the agent from `DESKTOP_TOOLS_AGENT` in the requesting client's environment, which `createDesktop` sets from its `agent` option; without it the label names the program that runs the client, as approvals do. Claude is orange, Codex blue, and any other agent gets a color fixed by its name; each agent has its own cursor and outline. For agents outside an embedding app, use the [Desktop Tools app](app.md).

The caller is the client's nearest ancestor that isn't `node`, `npx`, `npm`, a shell, `login` or `env`, such as Claude Code or the terminal app an agent runs in. Its key is the team ID and signing identifier of its running code when that signature validates, so an update that moves it keeps its approval; otherwise it is its path, plus its identifier when it has one. Its name is its app's name, else the last part of a team-signed identifier (`claude-code`), else its file name. The process can't choose either one through its arguments or environment.

## Run the host as an app's own helper

An app that runs agents itself, such as [AIDE](https://github.com/githubnext/aide), can start `desktop-tools-host` as its own child process instead of loading the runtime. macOS charges a child's Accessibility and Screen Recording use to the app that spawned it (its *responsible process*), so the helper uses the app's grants: one row in System Settings, no second app to approve. Spawn it with `posix_spawn` or `Process`, never through LaunchServices (`open`), which makes it its own responsible process.

```sh
desktop-tools-host <socket> --client <team>:<identifier> --protect <app pid> --parent <app pid> --overlays --confirm-stdio
desktop-tools-host --tools   # prints {"tools": [...], "instructions": "..."} and exits
```

- `--client` serves only that signed client, checked by the peer's audit token. The app connects to the socket itself.
- `--protect` refuses agent input whose target is that process (`SELF_TARGET_REFUSED`). The app shows and guards its own prompts.
- `--parent` exits when that process does.
- `--overlays` draws the agent cursor and the outline on the window being used.
- `--confirm-stdio` asks the app to confirm agent-supplied passwords: the host writes `{"confirm": id, "request": {...}}` and `{"withdraw": id}` lines to stdout, and reads `{"answer": id, "allowed": true|false}` lines on stdin. The request has `title`, `message`, `allow`, `deny`, `agent_name`, `app`, `web_host` when the field is in a web page, and `agent`, the key of the agent that asked.
- With `--overlays` or `--confirm-stdio` the host serves through this runtime, so the client must be signed by the host's own team.

A client that serves several agents over its one connection names each call's agent in the request, `{"id", "tool", "arguments", "agent": {"key", "name", "kind"}}`, so each gets its own cursor and outline, named and colored for it (`kind` `claude` is orange, `codex` blue).

Every host refuses agent input to System Settings and to the system's permission and password prompts (`SYSTEM_UI_REFUSED`): a Privacy & Security switch, Allow on a "would like to control this Mac" prompt, or an administrator password would give the agent more than the user did. Opening, reading and quitting them still work.
