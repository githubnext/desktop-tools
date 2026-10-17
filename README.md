# desktop-tools

Native macOS desktop inspection and input for agents: a Swift runtime that a signed app embeds, a signed client CLI that talks to it over a Unix socket, and a TypeScript client, protocol, and MCP server. The native parts require macOS 15 or later.

- **Agents such as Claude Code or Codex:** set up as below, or see [MCP](docs/mcp.md) for more options.
- **Apps:** [embed the runtime](docs/embed.md) and use it [from Node](docs/node.md).

## Set up for an agent

You need macOS 15 or later and Node 22 or later. The MCP server runs from this repository through `npx`; the package isn't on the npm registry.

1. **Install the app.** Download the DMG from the [latest release](https://github.com/githubnext/desktop-tools/releases/latest), drag **Desktop Tools** to Applications, and open it. It runs in the menu bar.
2. **Grant permissions.** From its menu, grant Accessibility, Screen Recording and Keyboard input. The grants belong to the app, not to your terminal or agent.
3. **Add the MCP server** to your client. The `#v…` suffix pins a release tag; leave it off to follow `main`.

   Claude Code:

   ```sh
   claude mcp add desktop -- npx -y --package=github:githubnext/desktop-tools#v0.12.0 desktop-tools-mcp
   ```

   Codex, in `~/.codex/config.toml`:

   ```toml
   [mcp_servers.desktop]
   command = "npx"
   args = ["-y", "--package=github:githubnext/desktop-tools#v0.12.0", "desktop-tools-mcp"]
   ```

   Other MCP clients that start stdio servers from JSON, such as Cursor or Claude Desktop:

   ```json
   {
     "mcpServers": {
       "desktop": {
         "command": "npx",
         "args": ["-y", "--package=github:githubnext/desktop-tools#v0.12.0", "desktop-tools-mcp"]
       }
     }
   }
   ```

4. **Verify.** Ask the agent to call `desktop_apps`. It should list the running apps with an `inventory_completeness` of `complete`. If it says the socket is missing, open the app and check that **Serve agents** is on.

Any process running as you can use the app's grants while it serves agents. Quit it when you don't need it.

Documentation is at [githubnext.github.io/desktop-tools](https://githubnext.github.io/desktop-tools/), built from [`docs/`](docs/).

MIT licensed. Native builds link third-party code whose [licenses](docs/licenses.md) must ship with them.
