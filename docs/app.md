# Desktop Tools app

`Desktop Tools.app` (`dev.githubnext.desktop-tools`) is a menu bar host for agents that don't embed the library, such as Claude Code or Codex through the [MCP server](mcp.md). It holds its own Accessibility, Screen Recording and Keyboard input grants, shown and requested from its menu, and serves `~/.local/state/desktop-tools/desktop.sock`. It links `desktop-client` there to its signed client. Turning off **Serve agents** stops the runtime. **Show agent cursor**, on by default, draws the agent's own pointer for each click, scroll, drag, hover and press. **Highlight agent's window**, also on by default, outlines the window the agent is observing or acting on and labels it with the agent and app, such as "Claude is using TextEdit". See [input](tools.md#input).

## Install

Download the notarized DMG from the [latest release](https://github.com/githubnext/desktop-tools/releases/latest), drag **Desktop Tools** to Applications, and open it. Grant each permission from its menu.

Anything running as the user can use those grants while the app serves, so grant them only on machines where that is acceptable, and quit the app when it isn't needed.

**Recent Activity** in the menu lists the last 5 operations agents ran. **All Activity** holds the last 20. Each line names:
- the operation, such as Click, Key, Type, Capture or Read clipboard;
- the target app and window title;
- the agent (`DESKTOP_TOOLS_AGENT`, or the name of the process that ran the client, such as `node` for the MCP server) and that process's pid;
- the time;
- the outcome: completed, unknown, refused, or paused for a request refused because input was paused.

Identical operations in a row fold into one line with a count. Every desktop change is listed, and so are screen captures and clipboard reads. Listings and snapshot bookkeeping are not. Only the operation and its target are kept, never typed text, clipboard contents or values. The list lives in memory and is gone when the app quits.

**Pause All Input** stops agents from changing anything until you turn it off again. While paused, the app refuses every click, key, typing, scroll, drag, menu command, app or window change, dialog action and clipboard write before it is sent. The refusal tells the agent to ask you to resume. Agents can still observe: listings, the accessibility tree, screen captures and clipboard reads keep working. The menu bar icon becomes a pause sign while input is paused. Only this menu item changes it; no client can pause or resume. Pausing isn't saved, so the app starts resumed. `desktop_input_source` select runs in the client rather than through the app, so pausing does not stop it.

## Build

```sh
node dist/app.js --out build --identity "Developer ID Application: … (TEAM)" --release
```

`assemble(out, scratch?)` and `sign(app, identity, release)` in `dist/app.js` are what the release workflow uses.

## Development

A development build run alongside the installed app needs its own state directory. Otherwise it relinks `~/.local/state/desktop-tools/desktop-client` to its own client; it cannot take over `desktop.sock` while the installed app serves it. Set `DESKTOP_TOOLS_STATE` for both the app and the MCP server:

```sh
open -n --env DESKTOP_TOOLS_STATE=/tmp/desktop-dev "build/Desktop Tools.app"
DESKTOP_TOOLS_STATE=/tmp/desktop-dev node dist/mcp.js
```

The app then serves `/tmp/desktop-dev/desktop.sock` and links its client there, and the MCP server uses both by default. A build signed with the same identity and identifier as the installed app shares its macOS grants.
