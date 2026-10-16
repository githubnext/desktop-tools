# desktop-tools

Native macOS desktop inspection and input for agents: a Swift runtime that a signed app embeds, a signed client CLI that talks to it over a Unix socket, and a TypeScript client, protocol, and MCP server. The native parts require macOS 15 or later.

- **Agents such as Claude Code or Codex:** install the [Desktop Tools app](https://github.com/githubnext/desktop-tools/releases/latest), then [add the MCP server](docs/mcp.md).
- **Apps:** [embed the runtime](docs/embed.md) and use it [from Node](docs/node.md).

Documentation is at [githubnext.github.io/desktop-tools](https://githubnext.github.io/desktop-tools/), built from [`docs/`](docs/).

MIT licensed. Native builds link third-party code whose [licenses](docs/licenses.md) must ship with them.
