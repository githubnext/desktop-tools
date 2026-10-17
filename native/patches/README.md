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
native title-bar click. The target may still be handling its activation record when the read-only
admission before the click runs, so a refused admission is read again at most twice, 50 ms apart;
input proceeds only after a complete admission, and a refusal that persists keeps the posted
preparation uncertain. The route is fixed before input and never switches after partial delivery.
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
Titles match exact UTF-16, including ellipses. A title with no match refuses with its path level,
the bounded sibling titles already read, and a lone sibling that only adds a trailing ellipsis.
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

`peekaboo-sheet-window.patch` attributes sheet controls to the window the sheet is attached to,
for [Save sheets refusing every mutation](https://github.com/githubnext/ace/issues/378). A sheet
is its own WindowServer window but is absent from the application's AXWindows, so an exact-window
observation reaches it only through the parent window's tree. A sheet control's AXWindow link names
the sheet, and an Open or Save panel's controls resolve to the Open and Save Panel Service's own
window; neither matches the observed window, and the detached identity read used before value and
focus writes accepted only that link. The shared owning-window resolver now accepts the AXWindow
link only when it is a same-process `AXWindow`; otherwise it walks a bounded `AXParent` chain to the
nearest same-process `AXWindow`. An element with no such ancestor keeps its direct window identity.
The detached reader resolves through the same helper under its deadline, so element identity,
exact-window click receipts, and post-write observation agree. Sibling windows are still refused.

`peekaboo-sheet-focus.patch` extends that attribution to keyboard input, for
[literal insertion refusing a Save sheet's filename field](https://github.com/githubnext/ace/issues/390).
The exact focused-element receipt read before keyboard input, literal insertion and paste still
required the receiver's own `AXWindow` link to name the observed window, and an Open or Save panel
field can have no link at all (kAXErrorNoValue). It now resolves the owner through the shared resolver,
which also reports the nearest attached sheet on the way to that window; focus corroboration during
observation uses the same resolver. Because a sheet takes keyboard focus from its parent, a receiver
inside a sheet is admitted only while that exact sheet is the application's focused window, and a
receiver outside any sheet still requires the observed window itself. A parent window with an attached
sheet, another sheet, and sibling windows remain refused.

`peekaboo-restore.patch` keeps a confirmed restore from reporting an unknown outcome while the
Dock's unminimize animation runs, found in the [Ace desktop study](https://github.com/githubnext/ace/issues/427).
The service confirms an exact minimized restore by repinning unchanged WindowServer bounds, so the
bridge's single readback could still see Accessibility report the window minimized. Only that
requested-state mismatch for `restoreWindow` is read again, at most 8 times 100 ms apart; each read
posts no input and repeats the full identity, process-generation and bounds validation. Identity
failures, lookup errors and a window that stays minimized remain indeterminate.

`peekaboo-title.patch` lets an Accessibility observation succeed while the window's title changes,
found in the [Ace desktop study](https://github.com/githubnext/ace/issues/427). The resolver reads the
title from WindowServer; the traversal reads it again from Accessibility, so a page with a live title
failed binding validation with `window-context window title`. A window context that names a window is
already pinned by that exact window ID, its WindowServer receipt and bounds, and one process generation,
and the traversal selects its AX window by that ID, so its title is no longer compared. A context without
a window ID still must match the title. The resolved target keeps its title; the client reports the newer
traversal title. Input actions bind by window ID, receipt and focused-element identity, never the title.

`peekaboo-agent-cursor.patch` shows background pointer input on screen, since it never moves the
physical pointer. Peekaboo already accepts an `AutomationFeedbackClient`, but before this patch none
of the operations Desktop Tools serves called it: targeted and exact-window clicks, background
scrolls and PID-routed hotkeys deliberately skip feedback, and exact-window drag, literal insertion
and value writes have none. Exact-window and generation-pinned clicks now pass the click service a
lane preparation that reports the coordinate, or the snapshot element's center, in global display
points. It runs inside the lane before preparation revalidates the target, so a target that changes
while the cursor moves is refused exactly as before. Background scrolls report their point or element
in their existing lane preparation, which runs before the action route's own revalidation. Exact-window
drags report both endpoints before the held-pointer lifecycle starts, so feedback never spends the
hold's expiry budget. Feedback cannot throw and never decides the input: dispatch waits for it at most
600 ms, then proceeds while a late feedback task finishes alone. The default no-op client adds no wait.
Target checks, routes, outcomes and retries are unchanged, and the existing post-dispatch visualizer
calls stay suppressed for background input. Keyboard operations still report no feedback.

`peekaboo-dock-exact.patch` makes Dock presses and Dock context-menu choices select by exact title only,
for `desktop_dock`. `DeterministicDesktopLeafSelector.select(named:)` falls back from an exact title to
normalized, punctuation-folded and partial matches, so a title that no longer exists could press a
different Dock item or menu item. An `exactOnly` flag, off by default, limits the permitted match kinds
to `.exact`; the Dock item and context-menu lookups pass it. A missing or repeated title refuses before
input. Other selectors keep their upstream fallback, and the test covers folded, case and partial
refusals.

`peekaboo-menubar-ax.patch` lists and presses status items on macOS versions where `MenuBarAgent` draws
the whole menu bar, for `desktop_menubar_items` and `desktop_menubar_click`. There, WindowServer has no
window per status item, so the window inventory returned only `MenuBarAgent`'s bar windows and the click
route had nothing exact to target. When a `MenuBarAgent` window is among the window extras, the listing
instead reads each running process's `AXExtrasMenuBar`, concurrently with a 250 ms messaging timeout,
and keeps its `AXMenuBarItem`s (descending only through groups) with their owner process, identifier,
title or description and full Accessibility frame, ordered left to right. `MenuExtraInfo` gains an
optional size so the selected-leaf evidence carries the real frame instead of a 1-point box. An indexed
click on such an item keeps the existing double listing and evidence checks, then resolves exactly one
element in the owner's extras bar with the same identifier and frame, checks the owner's process
generation, and performs one AXPress, or AXShowMenu where press is absent. NSMenu-backed items reply
only after their menu closes, so the press uses a 500 ms timeout; a `cannotComplete` reply counts as
delivered only when a new overlay window appears near the bar within 500 ms, and otherwise stays an
unsafe unknown. The receipt targets the owner process. Hosts without `MenuBarAgent`, and items that
have their own window, keep the upstream window-routed path.

`peekaboo-agent-window.patch` tells the embedding app which window each request targets, so it can
outline that window. The embedded runtime's configuration gains a `targetWindowObserver`, passed
through the bootstrap to the Bridge server. After a request passes authorization and before it is
dispatched, the server reports the requesting peer's PID with the owner PID and window ID of an exact
window: a desktop observation pinned to a window ID, the window recorded in the snapshot whose
mutation lease or literal insertion it begins, or a window-scoped mutation such as a move, resize or
drag. Requests for screens, apps, menus or the clipboard report nothing, and nothing is reported for
refused peers. The report is advisory: it cannot fail the request and changes no target check, route
or outcome. Without an observer the server does no extra work.

`peekaboo-press.patch` shows a held pointer on the agent cursor, for `desktop_press`. Before the
service begins an exact-window hold, it sends long-press click feedback at the hold's point, under the
same 600 ms limit as other background pointer feedback. After a release, revoke or owner disconnect
that ends a hold, however it ended, it sends a single click at the receipt's point, so the overlay can
show the button coming up. A disconnect that finds no active hold sends nothing. Drags use the
lifecycle internally and are unchanged. Holds, receipts, cleanup and outcomes are unchanged, and the
test checks the feedback order and points.

`peekaboo-layout-keys.patch` lets a hotkey name the key that types a character on the current keyboard
layout, so `desktop_key` can send punctuation and every other printable key. Named
keys use fixed ANSI key codes, which type other characters on other layouts, and the hotkey string
cannot carry `,` or `+` literally. A `char:<hex scalar>` name is resolved on the GUI's main thread through
Text Input Sources and `UCKeyTranslate`, after every modifier is parsed: the key must type exactly that
printable character with no modifier but Command, which participates because layouts such as
"Dvorak - QWERTY ⌘" switch keys while it is held. Dead keys and keypad keys never match. A character that
needs Shift or Option, or that the layout lacks, is a typed pre-dispatch refusal whose message names the
unmodified key; Shift is never added implicitly, so the chord holds only the modifiers it names, and
the needed modifier differs between layouts. The resolved key keeps the character as its name, so the
paste, select-all and background shortcut policies still apply. Named keys, their codes and every other
caller are unchanged. The patch also names F13–F20 and the keypad keys, whose codes are layout-independent.

`peekaboo-element-action.patch` binds named Accessibility actions and value writes to the exact observed
element, for element actions and non-text values. Both resolved a target string by snapshot ID, then fell back
to a fuzzy label query, and re-found the live element by a score in which a matching label or frame alone
could select a neighbor; the only element check afterwards compared that live element with itself. With the
patch, `performAction` and `setValue` take only a literal element ID from the snapshot, and before input the
live element must match the observed element's receipt: process, owning window, role, frame, and identifier
or title. An observed `group-` identifier prefix that observation strips is compared in its native form. A
mismatch is a typed pre-dispatch `SNAPSHOT_STALE` refusal; the same receipt is checked again immediately
before the action. Named actions run off MainActor like `AXPress`: `AXShowMenu` reports delivery after the
existing show-menu grace period while its menu tracks, and every other action keeps the operation lane until
the native call returns. A failure that may follow delivery stays indeterminate, with no fallback route.
A checkbox, switch, or disclosure triangle whose value is read-only but which advertises `AXPress` (as
SwiftUI checkboxes do) is set by at most one press: a state already matching the request sends nothing, a
mixed or unreadable state refuses, and only a readback of the requested state on the same element confirms
the change. The `setValue` result contract accepts that press's Accessibility-action delivery. Observation
also records each element's advertised standard action names, at most 16 of up to 48 ASCII letters, in an
`actions` attribute; custom actions, which carry app text, are omitted. Tests whose resolver returns a stand-in AX element inject a
matcher that accepts it; two new tests cover a mismatched live element and a label in place of an element ID.

`peekaboo-drag-settle.patch` makes the global drag usable for drag and drop between windows and apps, for
`desktop_drag` with `to_snapshot`. `GestureService` posted the press and its first drag event back to
back, and released on the last path point at once, so AppKit drag sessions often never started or the
destination never accepted the drop. The drag now waits 150 ms after the press, then rests over the end
point for 150 ms, posting three drag events there, before releasing. The release still runs on every
exit, including cancellation. Path, steps, timing between steps and modifiers are unchanged, and the
exact-window drag doesn't use this path.

`peekaboo-element-depth.patch` records each observed element's depth below its window in a `depth`
attribute. Element IDs already follow the traversal's pre-order, so with depth a reader recovers each
element's subtree from the flat result: the elements after it with a greater depth, up to the next
one at its depth or above. `desktop_read` uses this to read one element's text in order, and a scoped
`desktop_inspect` to list one subtree. The traversal, its budgets, element IDs and snapshot authority are
unchanged; the attribute is observation metadata and no action reads it.

`peekaboo-lock-holder.patch` names what is blocking a desktop operation lane. When a lane lock wait
times out, the refusal now lists up to eight processes of the same user that have the lock file open,
each with its pid and executable path, and marks the timed-out process itself. The holder is among them;
the rest are other waiters. `flock` records no owner, and `F_GETLK` reports a held flock with pid -1, so
the list comes from each process's open file descriptors (`proc_pidinfo`), matched by device and inode.
Other users' processes can't be read and are left out. With no process found, the message is unchanged
and the hint says to wait and observe again. The refusal stays a pre-dispatch timeout. Two tests in
`LockFileHoldersTests.swift` use a temporary coordination root.

`peekaboo-focus-activation.patch` makes window focus see an app that is already frontmost and say why it
stopped when one isn't. Focusing a window first waits for its app to become active, and that wait read only
`NSRunningApplication.isActive` and `NSWorkspace.frontmostApplication`. Both are refreshed by notifications on
the host's main run loop and can lag. When the wait gave up, the error was "Timeout while waiting for
condition". The wait and the focus verification now also accept the system-wide `AXFocusedApplication`, read
from the Accessibility server with a 50 ms messaging timeout. A wait that still ends without the app in front
throws `FocusError.activationNotObserved`. That error names the app and pid, says whether macOS accepted the
activation request, and suggests activating the app and retrying, or asking the user to click the window.
Activation is still requested once, and the 3-second budget is unchanged. Two tests cover the message and a
process that doesn't exist.

`peekaboo-preparation-message.patch` says what a failed background keyboard preparation did and didn't send.
Preparation activates the target window and clicks its blank title bar before any key or paste. When it
stops partway, for example because the window ID read keeps failing while the app is busy (#18), the
outcome stays indeterminate, since the activation or click may have reached the app. The old message,
"Background keyboard preparation did not finish", read as if text might have been typed. It now says that
no keys or paste were sent. The caller sends keys only after preparation returns. The existing preparation
test checks the new wording.

`peekaboo-sck-quarantine.patch` makes a quarantined ScreenCaptureKit gate wait briefly and then
explain itself. When an SCK call times out, Peekaboo abandons it and quarantines the gate (and keeps
its cross-process lock) until that call's late callback arrives. A new capture now waits up to 2 s
for that callback before refusing, outside its own budget. The refusal says the quarantine is
temporary, is usually caused by another busy capture on the Mac, and clears by itself; it asks the
caller to wait a few seconds and retry. A timed-out wait for another process's capture says the same.
The private `SCShareableContent.fetchWindowForWindowID` lookup now has 3 s instead of 1 s: under
ordinary load its 1 s budget timed out and quarantined every later capture. The application inventory
budget grows from 1 s to 2.5 s, since a healthy inventory took 0.95 s; upstream deliberately refuses
an inventory that misses its deadline instead of returning it partial, so this patch keeps that.

There is deliberately no fallback around a quarantine. Peekaboo's "CGWindowList" window engine
captures through the private SCK lookup or `/usr/sbin/screencapture -l`, and `screencapture` itself
uses ScreenCaptureKit in its own process. `CGWindowListCreateImage` is obsoleted. Every remaining
capture path would therefore start ScreenCaptureKit beside the abandoned call, which upstream rules
out (`allowsSystemFallback`, "Private SCK fallback never crosses an abandoned operation"). Don't add
a fallback here; wait, refuse, and let the caller retry. The SCK gate lock stays per-user in
`$TMPDIR`, shared with every Peekaboo process; keying it to the host app would let separate
apps overlap ScreenCaptureKit calls again, which is what it prevents. `ScreenCaptureKitQuarantineGraceTests.swift` covers the
grace period and the message.

`peekaboo-dialog-path.patch` adds `exactFileDialogPath`, which chooses one absolute path in one exact
Open or Save panel without pressing its default button. Upstream `dialogHandleFile` finds the panel by a
fuzzy app name, clicks the panel's center to focus it, and presses the default button in the same call. The
new operation resolves the panel the way exact forced dismissal does, from an app, PID, or window selector,
and refuses a dialog that is not a file panel. An existing folder becomes the panel's folder; any other path
must name a file in an existing folder, which a Save panel (one with `saveAsNameTextField`) takes as its
folder and name, and an Open panel selects through Go to Folder. Folder and file paths resolve symlinks
before input, so `/tmp` compares as `/private/tmp`. The host focuses the retained panel's window, checks that the
panel holds keyboard focus before each key, expands a collapsed panel, sets the expanded panel's
`PathTextField` and presses Return, and falls back to Go to Folder (Command-Shift-G), whose new field is
set through Accessibility when it can be and typed otherwise. Nothing clicks the panel. The result is
`confirmedChange` only when the path field reads back the folder and, in a Save panel, the name field
reads back the name; otherwise it is `dispatchedUnverified`. Details report the readback. The descriptor,
permission set, semantic policy and result contract are listed in the upstream inventory tests, and new
tests cover path resolution and request validation.

`peekaboo-drag-path.patch` lets a drag follow a path. `ExactWindowDragRequest` and `DragOperationRequest`
take up to 16 `waypoints`, visited in order between `from` and `to`. `DragPolyline` samples the path in
straight segments with at least one sample per segment, shares the rest by segment length, and lands
exactly on every waypoint, so a straight drag samples the same points as before. The exact-window drag
keeps its sample count and dispatched unit count, and refuses waypoints outside its window or more
segments than samples. The foreground drag follows the same samples instead of its movement profile
when waypoints are given; its modifier keys were already supported. The bridge payload and the
exact-window request decode a missing `waypoints` as empty. Tests in
`ExactWindowHeldPointerLifecycleTests.swift` cover the samples, the refusals and decoding.

`peekaboo-minimized-close-test.patch` changes only a test. The upstream test "minimized identity may dispatch
when WindowServer omits its entry" stubs a missing owner for window 77, but not its bounds, so the server read
the bounds of any real WindowServer window 77. On a Mac where one exists, even off screen, the pinned close
was refused as a changed target and the test failed
([#50](https://github.com/githubnext/desktop-tools/issues/50)). The test now stubs missing bounds as well,
like the restore test after it. The server is unchanged.

`peekaboo-notification-actions.patch` lists and performs Notification Center's custom actions. Since
macOS 11 its banners and entries advertise them as `Name:Close\nTarget:…\nSelector:…` descriptors, for
Close, Show, Options and the posting app's own actions. Upstream observation keeps only standard `AX` action
names, and `performAction` accepts only letters, digits, `_` and `-`, so none of them can be seen or run. The
observation worker now lists, only when the traversed process runs Notification Center's executable, each
element's custom action names as `attributes.customActions`, one per line: at most 8, each at most 64
characters with no control characters, and never a name advertised twice. `performAction` accepts
`AXCustomAction:<name>` with the same snapshot, exact-element and process checks as any element action, and
also refuses it before dispatch unless the target process is Notification Center and the element lists
exactly that name. It performs the matching descriptor and reports the requested name, which the Bridge
receipt requires. No Bridge operation is added. Built against the macOS 11 to 15 structure; tests use fixtures.

`desktop-tools-build` resolves only `Package.resolved` versions, checks the pin and checkout revision,
and assembles the ordered patch stack in a private Git index. A build compares the checkout
with each complete ordered prefix, since later patches can change earlier patch contexts.
Only the missing suffix is applied, then verified against the complete expected source before
compiling Swift. Keep new patches at the end so an existing complete stack remains a valid prefix.
A checkout matching no prefix, such as one built from an earlier revision of a patch, is build
scratch: it is restored to the pinned revision and receives the complete stack. The real dependency
index is unchanged, and the build never compiles unexpected source. Patch files are excluded from
formatting.

Each patch carries the upstream test updates its behavior requires. A patch that adds a Bridge
operation also updates upstream's operation inventory in `Core/PeekabooCore/Tests/PeekabooTests`: the
wire count in `PeekabooBridgeRequestPlanTests` and `PeekabooBridgeOperationSemanticPlanTests`, the
permission partition in `PeekabooBridgeRequestPlanTests`, and the mutating operations in
`PeekabooBridgeOperationResultSemanticsTests`. With the complete stack, `swift test` in
`Core/PeekabooAutomationKit` and `Core/PeekabooCore` builds without local edits.

Peekaboo's tests take the real per-user `~/.peekaboo` locks, whatever `HOME` is. Run them in the
foreground with a narrow `--filter` and a hard time limit, and never leave a run in the background:
a stuck run blocks every desktop operation on the Mac, including the installed app. Run
`PeekabooAutomationKitTests`, `PeekabooBridgeTests`, and the `PeekabooTests` Bridge suites (files
named `*Bridge*`) in a few batches. Two upstream tests also
fail on unpatched Peekaboo 4.8.0 on some hosts:
`DesktopObservationServiceTests.testGenerationlessRemoteExactObservationStaysReadOnly` when a real
WindowServer window 42 exists, and the PeekabooBridge test "Cancellation reaps the exact child
without a zombie".

When updating Peekaboo, review the upstream fixes and these patches together. Update the revision
guard and patches deliberately, or remove each patch when the dependency includes its fix.
Revalidate real button clicks, changed-focus refusal, literal multiline insertion, clipboard
restoration, partial input, and interruption before shipping
the update.
