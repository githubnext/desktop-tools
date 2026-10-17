# Desktop Tools app

`Desktop Tools.app` (`dev.githubnext.desktop-tools`) is a menu bar host for agents that don't embed the library, such as Claude Code or Codex through the [MCP server](mcp.md). It holds its own Accessibility, Screen Recording and Keyboard input grants, shown and requested from its menu, and serves `~/.local/state/desktop-tools/desktop.sock`. It links `desktop-client` there to its signed client. Turning off **Serve agents** stops the runtime. **Show agent cursor**, on by default, draws the agent's own pointer for each click, scroll and drag, since the physical pointer never moves. **Highlight agent's window**, also on by default, outlines the window the agent is observing or acting on and labels it with the agent and app, such as "Claude is using TextEdit". See [input](tools.md#input).

## Install

Download the notarized DMG from the [latest release](https://github.com/githubnext/desktop-tools/releases/latest), drag **Desktop Tools** to Applications, and open it. Grant each permission from its menu.

Anything running as the user can use those grants while the app serves, so grant them only on machines where that is acceptable, and quit the app when it isn't needed.

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
