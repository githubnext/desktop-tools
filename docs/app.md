# Desktop Tools app

`Desktop Tools.app` (`dev.githubnext.desktop-tools`) is a menu bar host for agents that don't embed the library, such as Claude Code or Codex through the [MCP server](mcp.md). It holds its own Accessibility, Screen Recording and Keyboard input grants, requested from its menu while any is missing, and serves `~/.local/state/desktop-tools/desktop.sock`. It links `desktop-client` there to its signed client. **Show agent cursor**, on by default, draws the agent's own pointer for each click, scroll, drag, hover and press. **Highlight agent's window**, also on by default, outlines the window the agent is observing or acting on and labels it with the agent and app, such as "Claude is using TextEdit". See [input](tools.md#input).

## Install

Download the notarized DMG from the [latest release](https://github.com/githubnext/desktop-tools/releases/latest), drag **Desktop Tools** to Applications, and open it. Grant each permission from its menu.

Anything running as the user could use those grants, so the app asks before serving each agent (see [approved agents](#approved-agents)). Grant them only on machines where that is acceptable, and quit the app when it isn't needed.

## Approved agents

The first time an agent calls, the app asks **Allow *name* to control this Mac?**, naming who signed it and where it runs from, with **Allow** and **Don't Allow**. Until you answer, and after Don't Allow, every request from that agent is refused with `CALLER_NOT_APPROVED`, listings and screen captures included; the agent is told to ask you, and is never left waiting. The answer is remembered in `callers.json` in the state folder (`~/.local/state/desktop-tools`), readable only by you, and the app asks about each agent once. Updating from 0.13.1 or earlier, each agent you use is asked about once.

The agent is the program that ran the MCP server, skipping `node`, `npx` and shells: Claude Code is `claude-code`, and a server run from a terminal is that terminal app. Signed programs are recognized by their signature, so an update keeps its approval; unsigned ones by their path. **Approved Agents** in the menu lists every agent with who signed it and its path: revoke an allowed one, allow one you refused or forget it so it's asked about again, or answer one still waiting.

The app's own prompts, menus and windows answer only to you. Agent input aimed at any Desktop Tools process, including the app, its client and another build of it, is refused with `SELF_TARGET_REFUSED`, and so is every agent input while one of its prompts or menus is open. Agents can still observe them.

**Open Log** in the menu opens `activity.log` in the state folder, in Console unless you chose another app for `.log` files. Each line has the time and one operation an agent ran:
- the operation, such as Click, Key, Type, Capture or Read clipboard;
- the target app and window title;
- the agent, as named under [Approved agents](#approved-agents), and its pid;
- the outcome: completed, unknown, refused, or paused for a request refused because input was paused.

Every desktop change is logged, and so are screen captures and clipboard reads. Turning on an app's web accessibility for a read is logged once per launch of that app. Listings and snapshot bookkeeping are not. Only the operation and its target are kept, never typed text, clipboard contents or values. The log also notes when the app starts, with the socket it serves, and when you pause input, or allow, refuse or forget an agent. The file is readable only by you; past 1 MiB it moves to `activity.log.1` and a new one starts.

The menu shows a **Grant** item only for a permission the app is missing. **Pause All Input** sits just above Quit.

**Pause All Input** stops agents from changing anything until you turn it off again. While paused, the app refuses every click, key, typing, scroll, drag, menu command, app or window change, dialog action and clipboard write before it is sent. The refusal tells the agent to ask you to resume. Agents can still observe: listings, the accessibility tree, screen captures and clipboard reads keep working. So does turning on a Chromium or Electron app's web accessibility before a read, since it only lets the app's web content be read and sends no input (see [tools](tools.md#input)). The menu bar icon becomes a pause sign while input is paused. Only this menu item changes it; no client can pause or resume, and agent input can't reach the menu. Pausing isn't saved, so the app starts resumed.

## Build

```sh
node dist/app.js --out build --identity "Developer ID Application: … (TEAM)" --release
```

`assemble(out, scratch?)` and `sign(app, identity, release)` in `dist/app.js` are what the release workflow uses. `assemble(out, scratch, true)` builds the development app instead, and `sign` takes the client's identifier from the bundle's.

## Development

Run development builds with `npm run dev-app`, described in [Install and build](build.md#development-app). It installs one `Desktop Tools Dev.app` (`dev.githubnext.desktop-tools.dev`) at a fixed path and serves `~/.local/state/desktop-tools-dev/desktop.sock`, so it never relinks the installed app's `~/.local/state/desktop-tools/desktop-client` or takes its socket. Point the MCP server at it:

```sh
DESKTOP_TOOLS_STATE=~/.local/state/desktop-tools-dev node dist/mcp.js
```
