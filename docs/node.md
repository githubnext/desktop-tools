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

Each request goes whole to the host, through its `desktop-tools-client`, as one tool call, so the host checks the arguments and shapes the result. One client process serves every call (`desktop-tools-client <socket> --serve`) and is replaced when it exits. Results take the compact shape described in [Result shape](tools.md#result-shape). Pass `verbose: true` in the config, or set `DESKTOP_TOOLS_VERBOSE=1`, for native results whole, with their `target_receipt`. Check the inventory completeness fields before relying on a listing. Image bytes appear only in `image`.

`client` must be the `desktop-tools-client` of a host that embeds the Swift runtime from `native2/` (#143), such as Desktop Tools 0.17.0 or later. The `wire` option, which chose it while the Peekaboo stack shipped beside it, is accepted and ignored.
