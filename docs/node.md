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
