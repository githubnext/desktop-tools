# desktop-tools

Native macOS desktop inspection and input for agents. It contains:

- A Swift runtime that a signed GUI app embeds. It serves a patched [Peekaboo](https://github.com/openclaw/Peekaboo) Bridge, and the app holds the macOS permissions.
- A signed client CLI that talks to that runtime over a Unix socket.
- A TypeScript client and a runtime-neutral protocol for Node or Bun hosts.

The native runtime and client require macOS 15 or later. The `protocol` export and the JavaScript modules install and import on any platform; only native operations need macOS.

## Guides

- [Desktop Tools app](app.md): a signed menu bar host for agents that don't embed the runtime.
- [Use from an MCP client](mcp.md): Claude Code, Codex, and other MCP clients.
- [Tools](tools.md): what agents can observe and do, and what isn't supported.
- [Use from Node](node.md): the TypeScript client and its results.
- [Embed](embed.md): ship the runtime inside your own signed app.
- [Install and build](build.md): Git installs, native builds, and the patch stack.
- [Licenses](licenses.md): notices native builds must ship.
