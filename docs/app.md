# Desktop Tools app

`Desktop Tools.app` (`dev.githubnext.desktop-tools`) is a menu bar host for agents that don't embed the library, such as Claude Code or Codex through the [MCP server](mcp.md). It holds its own Accessibility, Screen Recording and Keyboard input grants, shown and requested from its menu, and serves `~/.local/state/desktop-tools/desktop.sock`. It links `desktop-client` there to its signed client. Turning off **Serve agents** stops the runtime.

## Install

Download the notarized DMG from the [latest release](https://github.com/githubnext/desktop-tools/releases/latest), drag **Desktop Tools** to Applications, and open it. Grant each permission from its menu.

Anything running as the user can use those grants while the app serves, so grant them only on machines where that is acceptable, and quit the app when it isn't needed.

## Build

```sh
node dist/app.js --out build --identity "Developer ID Application: … (TEAM)" --release
```

`assemble(out, scratch?)` and `sign(app, identity, release)` in `dist/app.js` are what the release workflow uses.
