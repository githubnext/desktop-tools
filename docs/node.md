# Use from Node

```js
import { createDesktop } from "@githubnext/desktop-tools";

const desktop = createDesktop({
	client: "/Applications/Example.app/Contents/MacOS/desktop-tools-client",
	socket: "/path/to/desktop.sock",
	name: "Example",
	// Optional: names the agent in the host's window highlight, such as "Claude is using TextEdit".
	agent: "Claude",
});
const apps = await desktop({ op: "apps" }, AbortSignal.timeout(30_000));
```

Each result has:

- `text`: bounded JSON written for a model.
- `data`: the same final object, parsed.
- `image`: `{ data, mimeType }`, base64 JPEG or PNG bytes, when the result has one.
- `outcome`, for actions: `completed`, `refused`, or `unknown`.

Each request goes whole to the host, through its `desktop-tools-client`, as one tool call, so the host checks the arguments and shapes the result. One client process serves every call (`desktop-tools-client <socket> --serve`) and is replaced when it exits. Results take the compact shape described in [Result shape](tools.md#result-shape). Pass `verbose: true` in the config, or set `DESKTOP_TOOLS_VERBOSE=1`, for native results whole, with their `target_receipt`. Check the inventory completeness fields before relying on a listing. Image bytes appear only in `image`.

`client` must be the `desktop-tools-client` of a host that embeds the Swift runtime from `native2/` (#143), such as Desktop Tools 0.17.0 or later. The `wire` option, which chose it while the Peekaboo stack shipped beside it, is accepted and ignored.

## Embedding from Node

The npm package is a thin layer for embedders such as Ace. It holds no tool logic, which all lives in the Swift package in `native2/`:

- `createDesktop` (`@githubnext/desktop-tools`): the transport above, through the embedding app's own signed client.
- `@githubnext/desktop-tools/tools`: `desktopTools({ place, app })`, `desktopToolRules(app)`, `desktopRequest` and the limits. The descriptions, schemas and rules are declared in Swift (`native2/Sources/DesktopProtocol/ContractTools.swift`), and the package exports them from `src/contract.ts`, which `npm run contract` generates from that file. `place` and `app` fill in where the tools act and which app holds the permissions. `desktopRequest` keeps the arguments the tool's schema names; the host checks them all, including the exclusive forms a schema can't state.
- `@githubnext/desktop-tools/protocol`: the request and result types, the named keys and wait conditions (generated from the same declarations), and `isDesktopAction`, which follows each tool's declared action flag.
- `desktop-tools-build` and `desktop-tools-app`: build the Swift products and the app (see [Install and build](build.md)).
- `desktop-tools-mcp`: a launcher that runs an app's own Swift MCP server (see [Use from an MCP client](mcp.md#npx-setups)).

To serve your app's grants to MCP clients too, ship `desktop-tools-mcp` from the native build beside your client, signed with the same identifier (see [Embed](embed.md)). It names your app (its `CFBundleName`) in its instructions; pass `--socket` with the socket your app serves, since it looks for Desktop Tools' state folder otherwise.
