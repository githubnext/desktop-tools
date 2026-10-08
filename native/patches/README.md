# Native dependency patches

These patches apply to Peekaboo 4.8.0, revision
`4d43dc9d80cd2aa3787a27f54b76d692db1dcf8f`, in the order listed in `src/build.ts`. They were
developed in [Ace](https://github.com/githubnext/ace2), whose issues record each motivating
failure. "Ace" below names the embedding app that first shipped them; the same constraints apply
to any embedder. The patched Bridge operations share Peekaboo's protocol version, so the runtime
also advertises the `dev.githubnext.desktop-tools.protocol.1` host capability that the client
requires before sending any request.

`peekaboo-click.patch` addresses
[self-targeted Accessibility clicks blocking Ace's native bridge](https://github.com/githubnext/ace2/issues/61).

The patch moves semantic `AXPress` off MainActor so Ace can service its own Accessibility request.
It captures result metadata before dispatch and avoids querying removed non-tab controls after a
press. Exact target validation remains in place. The operation keeps its coordinator lane until
the native call returns, including after client cancellation; no timeout is treated as completed
input.
Ambiguous native press failures retain an indeterminate outcome, preventing Peekaboo from
falling back to another click after input may already have been delivered.

The patch also addresses [editable WebKit controls accepting a press without keyboard focus](https://github.com/githubnext/ace2/issues/106).
A single element click prefers the existing verified focus write for writable `AXTextField` and
`AXTextArea` controls when Accessibility value delivery is allowed. Other controls retain their
normal press behavior. The focus write runs off MainActor while the operation keeps its lane;
the original exact target checks and focus readback remain in force. An ambiguous write failure
retains an indeterminate outcome instead of allowing another input route. Point-click occlusion
and background paste behavior are separate parts of that issue.

`peekaboo-pointer-window.patch` addresses
[WebKit controls being reported as occluded](https://github.com/githubnext/ace2/issues/106).
Positional click validation and pointer receiver identification use Peekaboo's existing
containing-window resolver, including the native `AXWindow` link when a leaf has no direct window
ID. A different or unresolved window remains refused; process, generation, bounds, and target
checks are unchanged. It adds no coordinate-routing or input fallback.

`peekaboo-insert.patch` addresses
[literal newlines submitting web composers](https://github.com/githubnext/ace2/issues/76).
Unicode keyboard events are still keyboard events: WebKit can treat a newline as Return.
The patch exposes one GUI-owned literal insertion operation using a temporary plain-text paste.
It reuses the native clipboard transaction gate, preserves bounded prior contents privately,
and owns the snapshot lease and native process mutation lane through delivery, verification, and cleanup.
Exact process, window, focused receiver, text, and UTF-16 selection establish the intended edit.
Both the original and intended text must fit the complete 65,536-unit verification limit.
An exact receiver in the active frontmost app uses a direct targeted Cmd+V chord. That route
revalidates the retained editor, selection, active app, and process generation before every input
unit. Other targets use Peekaboo's target-only window preparation, including its guarded blank
native title-bar click. The route is fixed before input and never switches after partial delivery.
Preparation and delivery form one native outcome; partial preparation remains uncertain input and
cannot authorize a retry. If the paste key was never posted, clipboard restoration is safe even
when preparation or modifier input was emitted. Typed refusal causes
retain the native guard diagnostic without exposing clipboard contents or the compared text.
An observed meaningful edit authorizes generation-checked restoration; uncertain consumption
leaves the replacement or preserves newer contents, never restoring private prior contents
while a paste may still be pending. It has no typing fallback or delayed restore journal.
The existing clipboard gate durably reserves the target process generation before the paste key.
Unresolved delivery blocks later automated clipboard writes until a live read confirms the intended
edit or that exact process generation ends. Only reservation metadata survives a GUI restart;
no clipboard contents, hashes, or deferred restoration are persisted.

`peekaboo-quit.patch` preserves accepted but unfinished normal quit in
[native computer use](https://github.com/githubnext/ace2/issues/8).
A normal quit can leave an application waiting for an unsaved-work decision. That is one
dispatched operation with unverified completion and unsafe retry, not a safely repeatable no-op.
The quit-specific result validator permits this canonical outcome with `false` termination so
the existing bridge returns the boolean and its signed process receipt. Other false/success
contradictions stay errors. Force-quit behavior, target revalidation, and mutation lanes are unchanged.

`peekaboo-close.patch` makes background window close a single request for
[window management](https://github.com/githubnext/ace2/issues/73). It selects a supported `AXClose`
or exact close-button `AXPress` from read-only evidence before input, then rechecks the original
window ID, process generation and bounds immediately before that one action. No accepted or
ambiguous native result falls through to another close route. An accepted close whose window
remains open is unverified with unsafe retry, including when unsaved work opens a dialog.
Cancellation stops admission before input; once admitted, the existing mutation lane remains
held until the detached AX call actually settles. Confirmed disappearance retains the existing
bridge postcondition checks. Foreground fallback behavior is unchanged and is not exposed by Ace.

`peekaboo-clipboard-text.patch` adds explicit plain-text clipboard reads and persistent writes for
[clipboard access](https://github.com/githubnext/ace2/issues/72). It applies after the insertion patch
and reuses its GUI clipboard service and reservation gate. Reads require silent clipboard access,
one complete item, a stable generation, and a complete JSON result of at most 24,000 bytes; ordinary
alternate representations do not prevent reading its plain text. Reads do not enter or release the
gate. Writes accept at most 8,192 UTF-16 units, enter the existing gate, and retain native mutation
outcomes without returning clipboard contents. They never paste, snapshot prior contents, restore,
or add a separate journal. Unresolved paste ownership refuses writes across channels and GUI restarts.

`peekaboo-clipboard-image.patch` adds the read-only image format for the same
[clipboard access](https://github.com/githubnext/ace2/issues/72). The GUI requires silent read access
and one stable clipboard item, then validates a complete PNG/JPEG/TIFF representation within
10 MiB, one frame, and 64 million pixels. ImageIO renders an oriented preview off MainActor:
PNG at bounded sizes first, then explicitly white-composited JPEG if needed. Previews fit
1,600 pixels per side and 900,000 bytes and carry separate source/conversion metadata. The
generation is checked after rendering too. The operation has no mutation lane, gate admission,
temporary file, clipboard backup, or paste behavior; it reuses the existing read-only Bridge
and channel image result.

`peekaboo-launch.patch` classifies synchronous selector preparation failures before application
launch as refused without dispatch. A missing LaunchServices registration or invalid launch request
therefore receives the existing signed targetless refusal receipt, instead of an indeterminate
mutation receipt. The catch surrounds only preparation; native opening, activation, readiness,
mutation lane ownership, and all errors after dispatch keep their existing semantics.

`peekaboo-clipboard-image-write.patch` adds persistent image writes for #72. The host reads one
bounded regular file into memory; neither the native client nor GUI opens the source path.
ImageIO validates a complete PNG/JPEG/TIFF frame (10 MiB, 64 million pixels) off MainActor before
the existing clipboard reservation gate admits the write. The GUI writes the original bytes and
UTI through `setActionResult`, preserving native accepted/uncertain outcomes. The response contains
source metadata, never image bytes or prior clipboard contents. Cancellation before admission
does not write; cancellation or response loss after admission cannot imply undo or safe replay.
No temporary paste, file reference, backup, new lock, or journal is added.

`peekaboo-clipboard-files.patch` adds the read-only file-reference format for #72. The GUI
uses the same silent permission and stable-generation checks, with at most 32 advertised local
file URL items and a complete 24 KB JSON result. It preserves URLs, order, and decoded paths;
no file existence/content checks, path canonicalization, or remote access occurs. Unsupported
legacy filename lists, promises, mixed item kinds, invalid/nonlocal URLs and unreadable data
refuse without truncation when visible to Ace. macOS may filter references before delivery, so
absence does not establish what the originating app published. The typed read-only Bridge has
no mutation gate, backup or journal.

`peekaboo-point-focus.patch` gives single left coordinate clicks the same verified editable-field
focus behavior as element clicks for [native computer use](https://github.com/githubnext/ace2/issues/106).
The raw Accessibility hit test runs on the existing bounded read lane so a self-targeted app can
answer it. Only that read leaves MainActor; generation, exact window bounds, and containing-window
checks still run before input. Settable text fields choose focus before AXPress, with the existing
detached focus write and verified native focus receipt. Original identity and bounds are checked
again immediately before mutation. Positional AXPress waits for its actual return and retains the
operation lane through cancellation; an uncertain return remains unsafe to retry. No input runs in
the detached read, no failed action falls back to another route, and no caret position is promised.

`peekaboo-clipboard-files-write.patch` adds persistent file-reference writes for
[clipboard access](https://github.com/githubnext/ace2/issues/72). The host checks metadata for
existing regular files, directories, or symbolic links without reading contents or resolving links.
The GUI validates 1–32 literal paths and prepares a complete file URL list within the reader's
24 KB bound. A focused multi-item service method publishes one `public.file-url` representation
per item in one `writeObjects` call, with generation checks around publication. It reuses the
existing mutation result owner and outer pending-paste gate; it adds no backup, temporary paste,
promise, or new authority. Silent same-generation item readback can confirm publication;
unavailable verification retains the existing dispatched/unverified result. There is no fallback
or restore after publication, and no claim about a receiver's later handling of the references.

`peekaboo-open.patch` distinguishes accepted document/URL delivery from verified application launch
for [native computer use](https://github.com/githubnext/ace2/issues/8). The existing launch service
returns `dispatched_unverified` with `delivery_accepted` when its request contains items to open.
The original native delivery, accepted unit count, global lane ownership and signed process target
are retained. Readiness and activation do not prove that the app loaded the item. Launches without
items and all refusal/uncertainty paths are unchanged; the existing bridge contract already permits
this accepted outcome.

`peekaboo-menu.patch` adds literal external-application menu commands for
[native computer use](https://github.com/githubnext/ace2/issues/8). A distinct typed Bridge
operation carries the exact process generation and title array, avoiding the existing String
API's splitting, fuzzy normalization and intermediate presses. Fresh bounded raw AX traversal
requires a unique path and supported enabled leaf before one AXPress; lazy missing paths refuse.
The whole native operation runs off MainActor while retaining the existing process write lane
until actual return, with cancellation checked before dispatch. Per-element AX messaging timeouts
do not race or abandon native work. `cannotComplete` and other ambiguous delivery failures remain
one attempted, unsafe unknown action; successful delivery does not establish command completion.
Signed application receipts and canonical outcome validation remain mandatory. Commands targeting
the native Ace process itself refuse before input; its menu inventory remains available. No
intermediate presses, separate activation request, fallback, automatic screenshot, or command retry
is added. The target app or macOS may still bring the app forward in response.

`peekaboo-stale-click.patch` reports exact-window clicks whose window already changed as refused for
[moved-window clicks](https://github.com/githubnext/ace2/issues/155). Click preparation runs before
any strategy route. It now checks the captured window identity and bounds there and throws a typed
pre-dispatch `target_unavailable` refusal with the `SNAPSHOT_STALE` code, a refresh hint, and the
captured exact-window target. Previously the first such check ran inside a route and its untyped
error reached the bridge's generic mapping, which conservatively reported possible dispatch.
Later route checks are unchanged: a route can follow an earlier Accessibility attempt that may have
dispatched, so a window change detected there still reports uncertain input. Long press keeps its
existing exact-window exemption, and process-generation checks are unchanged.

`desktop-tools-build` resolves only `Package.resolved` versions, checks the pin and checkout revision,
and assembles the ordered patch stack in a private Git index. A build compares the checkout
with each complete ordered prefix, since later patches can change earlier patch contexts.
Only the missing suffix is applied, then verified against the complete expected source before
compiling Swift. Keep new patches at the end so an existing complete stack remains a valid prefix.
The real dependency index is unchanged. Drift fails the build instead of producing unexpected
source. Patch files are excluded from formatting.

When updating Peekaboo, review the upstream fixes and these patches together. Update the revision
guard and patches deliberately, or remove each patch when the dependency includes its fix.
Revalidate real button clicks, changed-focus refusal, literal multiline insertion, clipboard
restoration, partial input, and interruption before shipping
the update.
