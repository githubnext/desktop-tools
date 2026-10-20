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
- `image`: a base64 JPEG or PNG, when the result has one.
- `outcome`, for actions: `completed`, `refused`, or `unknown`.

Results take the compact shape described in [Result shape](tools.md#result-shape); the client checks each receipt before it compacts one. Pass `verbose: true` in the config, or set `DESKTOP_TOOLS_VERBOSE=1`, for native results whole, with their `target_receipt`. Check the inventory completeness fields before relying on a listing. Image bytes appear only in `image`.

## The Swift host (wire 2)

`wire: 2` points the same API at the Swift host in `native2/` (#143), which runs beside the shipped one until the cutover. `client` is then native2's `desktop-tools-client`, and `socket` the native2 host's. Each request goes to the host whole, as one tool call, so the host checks the arguments and shapes the result; `verbose` still asks for the whole result. The MCP server takes the same choice as `--wire 2`. See [native2/CUTOVER.md](https://github.com/githubnext/desktop-tools/blob/main/native2/CUTOVER.md) for what still differs.
