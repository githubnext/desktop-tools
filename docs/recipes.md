# Recipes

Tool sequences for tasks that take several calls. Each recipe lists the calls in order, what each should return, a final check, and where it tends to go wrong. See [tools](tools.md) for each tool's contract.

The tool behavior described here comes from the code. How each app lays out its UI, such as button titles, roles and which process owns a panel, was not observed live and is marked *(unverified)*. When the observed UI differs, follow what the inspection shows.

Conventions:

- **inspect** means `desktop_inspect` with the window's `pid` and `window_id` from `desktop_windows`. Each completed action returns a fresh observation, so use its `snapshot_id` and element IDs for the next action. Snapshots are single-use.
- **app target** means `{pid, process_start_identity_decimal}` from `desktop_apps`. **Window target** means the `target` object of a `desktop_windows` row.
- After `refused` or `unknown`, observe again before acting. Never repeat input blindly.
- Shell commands are fine for files: checking that a file exists, `cp`, `hdiutil`. They are no substitute for the desktop tools on UI steps.

## Print to PDF

If the app has **File > Export as PDF…**, as Preview, Pages, Safari and Notes do, use it: it opens a Save panel directly and skips steps 2 to 5.

1. `desktop_menu` with the app target and `path: ["File", "Print…"]`. Menu titles are exact, including the `…` character; read them with `desktop_menus` if unsure. Expect `completed`.
2. `desktop_wait` with `until: "dialog_appears"` and `pid`. Expect `matched`. The print panel is a sheet or a window of the app.
3. inspect the window that holds the panel. Find the **PDF** menu button at the bottom left *(unverified: role `AXMenuButton`, title `PDF`)*.
4. `desktop_click` the PDF button. The fresh observation lists the open menu's items first.
5. `desktop_element_action` with `action: "AXPick"` on **Save as PDF** (or `desktop_click` it). A Save panel opens.
6. `desktop_dialog` with the app target. Expect `is_file_panel` true. Use its resolved window target for the next calls.
7. `desktop_dialog_answer` with `path: "/Users/me/Desktop/out.pdf"`. Expect `completed`: the panel reads back the folder and name.
8. `desktop_dialog_answer` with `button: "Save"`.

**Verify:** `test -s /Users/me/Desktop/out.pdf` in a shell, or `desktop_wait` with `until: "dialog_gone"` and then check the file. Printing to PDF writes the file a moment after the panel closes.

**Goes wrong:**

- Chrome, Firefox and Electron apps use their own print preview *(unverified)*. Choose **Save as PDF** as the destination there instead of the PDF menu.
- More than one dialog open in the app makes `desktop_dialog` refuse; pass the window target.
- An existing file at the path makes the panel ask to replace it. Read it with `desktop_dialog` and answer deliberately.

## Pick a color in the Colors panel

1. Select what the color applies to: for text in TextEdit, `desktop_select` the text.
2. `desktop_menu` with `path: ["Format", "Font", "Show Colors"]`, or `["Format", "Show Colors"]` depending on the app *(unverified per app)*.
3. `desktop_wait` with `until: "window_appears"`, the app's `pid` and `title: "Colors"`. The panel belongs to the app's own process.
4. inspect the Colors window. Click the **Color Sliders** tab in its toolbar *(unverified: an `AXRadioButton` or `AXButton`)*. Then choose **RGB Sliders** from the pop-up button, by `desktop_click` and `desktop_element_action` `AXPick`.
5. `desktop_type` the **Hex Color #** text field *(unverified label)* with `text: "FF8000"`. Expect `completed` with the value read back.
6. `desktop_key` with `key: "enter"`, using the snapshot from step 5's result.

**Verify:** inspect the panel again and check the hex field's value. Whether the selection took the color can only be seen in the app. Inspect it with `ocr` off and compare the screenshot, or read an attribute the app exposes *(unverified)*.

**Goes wrong:**

- The panel applies the color to the current selection or the key window's first responder. If focus moved, the color goes elsewhere or nowhere.
- The panel's layout differs per tab and macOS version.
- Setting the hex field without pressing Enter may not apply it.

## Choose a font in the Fonts panel

1. Select the text, as for colors.
2. `desktop_menu` with `path: ["Format", "Font", "Show Fonts"]`.
3. `desktop_wait` with `until: "window_appears"`, `pid` and `title: "Fonts"`.
4. inspect the Fonts window. The family list is long, so either:
   - type into the panel's search field to filter it *(unverified: an `AXSearchField` or `AXTextField`)*; or
   - inspect with `scope` set to the family table to list every row.
5. `desktop_click` the family row, then the typeface row, each from the latest observation.
6. `desktop_type` the size field with `text: "18"`, then `desktop_key` `enter`.

**Verify:** inspect the panel and check that the family and typeface rows read as selected (`isSelected`) and that the size field shows the value. The text itself carries no readable font through `desktop_read`.

**Goes wrong:**

- Clicking a row the panel scrolled away from: scope or scroll first, with `desktop_element_action` `AXScrollToVisible` when the row is listed.
- Apps with their own font pop-up in a toolbar or inspector, such as Pages, ignore the Fonts panel for some text. Use their pop-up like any pop-up button.

## Install an app from a DMG

The simplest verifiable route is the shell: `hdiutil attach`, then `ditto` the app into `/Applications`, then `hdiutil detach`. The desktop tools are needed for the first-launch prompt either way.

Through Finder:

1. `desktop_open` with `item: {path: "/Users/me/Downloads/App.dmg"}`. macOS may verify the image first.
2. `desktop_wait` with `until: "window_appears"`, `bundle_id: "com.apple.finder"` and `title_contains` set to the volume name. Allow `timeout_ms` up to 45000 for a large image.
3. inspect the volume window. Find the app icon and the **Applications** alias *(unverified: the image's own layout)*.
4. `desktop_drag` within that window, `from` the app icon's point `to` the alias's point. It's a background drag in one window.
5. `desktop_wait` with `until: "dialog_gone"` and the Finder pid, for the copy progress window *(unverified that progress shows as a dialog)*. Or poll the file with `test -d /Applications/App.app`.
6. `desktop_launch` with `application: {path: "/Applications/App.app"}`.
7. The Gatekeeper prompt ("App is an app downloaded from the Internet…") belongs to a system agent, not the app *(unverified: CoreServicesUIAgent)*. `desktop_notifications` lists system alerts under `system_alerts`. Read it with `desktop_dialog`, using the owner's app target from `desktop_apps`, then press **Open** with `desktop_dialog_answer`.
8. Eject: `desktop_menu` on Finder with `["File", "Eject \"Volume\""]` *(unverified title)*, or `hdiutil detach` in a shell.

**Verify:** `desktop_wait` with `until: "app_running"` and the app's `bundle_id`.

**Goes wrong:**

- Replacing an existing app, or installing a `.pkg`, asks for an administrator password. Password entry is not supported, so a person must do it.
- If the drag result is `unknown`, check the file before dragging again.
- The prompt can appear after a delay, or not at all for notarized apps that were already approved. Wait for it with a timeout and treat `timed_out` as "no prompt".

## Copy files between Finder folders

A shell `cp` is simpler. Use this when the copy must go through Finder.

1. `desktop_focus` the destination window target, `desktop_click` an empty part of its file list, then inspect it.
2. `desktop_insert` with `format: "files"` and the `paths`. It pastes them with Command-V and restores the clipboard once every name is in the folder.

To copy files picked in Finder instead, `desktop_click` the first one and the rest with `modifiers: ["command"]` (foreground, `unknown`; inspect to check the selection), then `desktop_key` `c` with `command`, and `desktop_key` `v` with `command` in the destination. Add `option` to move instead of copy.

**Verify:** the result is `completed` with `copy: "started"`. Large files may still be copying; `ls` the destination to check sizes.

**Goes wrong:**

- A name that already exists is refused with `PASTE_NAME_EXISTS` before anything is pasted. A manual Command-V would open a Replace / Keep Both / Stop dialog instead.
- A drag between Finder windows also copies, but its result is always `unknown`.

## Rename a file in Finder

A shell `mv` is simpler and can be checked. Finder shows a name written into a file's name field through Accessibility without renaming the file, so `desktop_set_cell`, `desktop_type` and `desktop_set_value` refuse it with `CELL_NOT_EDITABLE`. In Finder itself the rename is foreground input *(unverified)*:

1. `desktop_focus` the Finder window target, `desktop_click` the file's row, then inspect.
2. `desktop_key` `enter` to edit the name, then inspect.
3. `desktop_insert` the new name and `desktop_key` `enter`.

**Verify:** `ls` the folder. The row's text alone doesn't prove the rename.

**Goes wrong:**

- A name already in the folder makes Finder ask to use another name.
- With the window in the background, the name editor doesn't hold the window's keyboard focus and the insert is refused.

## Open something with Spotlight

`desktop_open` or `desktop_launch` is better when the target is known. Use Spotlight only for what needs its search.

1. `desktop_system_key` with `key: "space"` and `modifiers: ["command"]`. The result is `unknown`; nothing reads back a system shortcut.
2. `desktop_apps` with `query: "Spotlight"`, then `desktop_windows` with its pid, to find the search window *(unverified: on recent macOS the field may belong to another process)*. `desktop_apps`' `system.focus` also names where keyboard focus is now.
3. inspect the Spotlight window. `desktop_insert` the query; the field is the focused control.
4. `desktop_wait` with `until: "text_contains"` on that window, for a result line.
5. `desktop_key` with `key: "enter"`.

**Verify:** `desktop_wait` with `until: "app_frontmost"` and the expected `bundle_id`, or `window_appears` for a document.

**Goes wrong:**

- Command-Space can be rebound, for example to switch input sources. If no Spotlight window appears, press Escape with `desktop_system_key` and use `desktop_open` instead.
- The top hit can change while typing. Read the results before pressing Enter.

## Switch the input source

1. `desktop_input_source` with no arguments lists the enabled sources by `id`, `name` and `kind`, with `current`.
2. `desktop_input_source` with `select` set to the wanted `id`, such as `com.apple.keylayout.French`. It reads the source back.
3. Type, then select the `before` source again; the switch affects every app.

**Verify:** the result is `completed`, and `current` equals the requested ID.

**Goes wrong:**

- An unlisted source isn't enabled; the user adds it in System Settings > Keyboard > Text Input.
- An input method's mode may reach the app only after its next focus change. Inspect before typing.
- `unknown` means no readback within a second. List again rather than selecting again.
- `desktop_key` maps characters through `keyboard_layout`, so switch before typing with it.

## Use the share sheet

1. `desktop_menus` with the app target and `path: ["File"]`. This shows whether **Share** is a submenu of services or a single **Share…** command.
2. With a submenu, run `desktop_menu` with `path: ["File", "Share", "Mail"]` (the service's exact title). It opens that service directly.
3. With **Share…**, run `desktop_menu` with `path: ["File", "Share…"]`. A popover with service icons opens. `created_windows` may be empty, because the popover can be hosted by another process *(unverified)*. Find it with `desktop_screen`, which lists the windows on the display front to back, then inspect that window and `desktop_click` the service.

**Verify:** the service's own window. For Mail, use `desktop_wait` with `until: "window_appears"` and `bundle_id: "com.apple.mail"`; for AirDrop, the AirDrop sheet.

**Goes wrong:**

- Apps differ in where Share lives: in **File**, in a toolbar button, or in a context menu. A toolbar Share button opens the same popover as **Share…**.
- The popover closes when focus moves elsewhere. Act on it right after opening it.

## Set volume or brightness

To nudge the level, `desktop_system_key` with `volume_up`, `volume_down`, `mute`, `brightness_up` or `brightness_down`. Each press is one step and the result is `unknown`; `mute` toggles, so don't repeat it blindly. For an exact level, use Control Center:

1. `desktop_menubar_items`, then `desktop_menubar_click` the item owned by `com.apple.controlcenter`. Pick it by owner, not title.
2. inspect the window the click opened. Find the **Sound** or **Display** slider *(unverified: `AXSlider`, titles vary)*; its current value shows the range, 0 to 1 or 0 to 100.
3. `desktop_set_value` the slider. Expect `completed` with the value read back.

**Goes wrong:**

- Control Center closes when another app takes focus, which makes the snapshot stale. Reopen it and inspect again.
- Some modules open a detail view first, such as Display with an external monitor: click it, then inspect again.

## Zoom or rotate instead of pinching

There is no pinch or rotate gesture. Use the app's own command: it acts on an exact target, and you can read the result back.

1. `desktop_menus` with the app target, and look for zoom and rotate items in **View**, and rotate items in **Tools** or **Image**. Common items are **Zoom In**, **Zoom Out**, **Actual Size** and **Zoom to Fit** in Preview, Safari, Maps and Photos, and **Rotate Left** and **Rotate Right** in Preview and Photos *(unverified: titles and menus vary by app and macOS version)*. Each item shows its shortcut.
2. `desktop_menu` with the app target and that item's exact `path`. Expect `completed`. Repeat it to zoom further, observing between steps.
3. If the app has no menu item, use the shortcut on the window: inspect, then `desktop_key` with `=` and `command` to zoom in, `-` and `command` to zoom out, and `0` and `command` for actual size, against that snapshot. In Preview, `l` with `command` rotates left and `r` with `command` rotates right *(unverified)*. Pass `repeat` to press a key several times against one snapshot.

**Verify:** inspect the window. The zoom level often shows in a toolbar control, in the window title or in a status bar, and a rotated image changes its bounds. A menu item that became disabled, such as **Zoom In** at the largest size, means there is nothing further to do.

**Goes wrong:**

- Some apps use Command-Shift-= or Command-+ for Zoom In. Read the shortcut from `desktop_menus` rather than guessing it.
- Command-scroll and Control-scroll zoom only in some apps and only with the feature turned on, so they aren't a general substitute.
- Maps and other canvas views may not report the zoom level anywhere. Compare screenshots with `desktop_inspect` in pixels mode instead.
- Safari's View > Zoom In zooms the page. Pinch zoom in Safari magnifies the view instead, and no tool reproduces that.

## Fill a web form end to end

1. `desktop_open` with `item: {url: "https://example.com/form"}` and optionally `application: {bundle_id: "com.apple.Safari"}`.
2. `desktop_wait` with `until: "window_appears"`, the browser's `bundle_id` and `title_contains` set to part of the page title. Then `desktop_wait` with `until: "element_appears"`, that window's `pid` and `window`, and the first field as `element: {role: "AXTextField", title: "Email"}` *(the field's label as the page exposes it)*. Its result includes an inspection `snapshot_id` with the matching element IDs.
3. If the inspection is `truncated`, inspect again with `scope` set to the page's `AXWebArea` element.
4. For each text field:
   1. `desktop_click` the field. The fresh observation reports it as focused.
   2. `desktop_type` the field with that observation's `snapshot_id` and element ID. A web field is typed into with key events, so the page sees `input` and `change`. Expect `completed`; the field is read back.
5. For a `<select>`: `desktop_click` it, then `desktop_element_action` `AXPick` on the option, or `desktop_click` it. In Chrome and other Chromium browsers, pick with one `desktop_key` call instead: [pick from a native select in a browser](#pick-from-a-native-select-in-a-browser).
6. For a checkbox: `desktop_click` it, or `desktop_set_value` `true` *(unverified per site: some custom checkboxes ignore Accessibility values)*.
7. For a multi-line `<textarea>`: click it, `desktop_key` `a` with `command` to select its text, then `desktop_insert` with `route: "paste"`. Typed text can't contain newlines.
8. `desktop_click` the submit button.

**Verify:** `desktop_wait` with `until: "text_contains"` and the confirmation text, or `window_appears` with the next page's title. Then `desktop_read` the page if the outcome needs details.

**Goes wrong:**

- `desktop_type` on a web field that isn't focused is refused before any input, with a hint to click it first. Clicking is never done implicitly.
- Typed web text is at most 1,000 UTF-16 code units with no newlines or tabs.
- An `unknown` result means the readback didn't match. Autocomplete or input masks can reformat the text, such as phone numbers. Inspect before retrying.
- Password fields are refused, because password entry is not supported.
- An autocomplete popup can take focus after typing. Press `escape` with `desktop_key` before the next click if it covers the next field.

## Pick from a native select in a browser

A `<select>` shows in Accessibility as an `AXPopUpButton`. In Chrome and other Chromium browsers, its menu closes between tool calls, so clicking an item or `AXPick` from a later snapshot is refused, often with `SNAPSHOT_STALE`. `desktop_set_value` doesn't apply either: a pop-up button has no settable value. Pick in one `desktop_key` call instead. Background keys reach Chrome, so the browser can stay behind other apps.

1. inspect the browser window. Note the select's current value and check that it has keyboard focus. If not, `desktop_key` `tab` to it, or `desktop_click` it, which also opens its menu.
2. Find the options. If the menu is open, the inspection lists them as `AXMenu` and `AXMenuItem`, the highlighted one marked selected; if not, `desktop_key` `down` opens it, and the fresh observation lists them. n is the target option's index minus the current option's index.
3. If the menu is still open, as right after a click, send step 4's keys at once without the first Down. Otherwise it may already have closed by itself, or close it without changing the value with `desktop_key` `escape`; the select keeps focus.
4. `desktop_key` with `keys: [{key: "down"}, …n × {key: "down"}, {key: "enter"}]`, all in one call. The first Down opens the menu, the next n move the highlight, and Enter picks it.

**Verify:** inspect the window. The `AXPopUpButton`'s value reads back as the chosen option.

**Goes wrong:**

- The value didn't change: inspect to check that the select still has focus. As a fallback, `desktop_activate` the browser, inspect, and send the keys again.
- Separators and disabled items in the menu are skipped by Down, so count only the items that can be chosen *(unverified)*.
- When n is negative, send that many `up` in place of the Downs.
- A sequence takes at most 16 keys, so it reaches at most 14 options away.
- Outside Chromium browsers, as in native apps, `desktop_click` the pop-up button, then `desktop_click` or `AXPick` the item from the next observation.

## Copy text from a web page

1. inspect the browser window. If the inspection is `truncated`, inspect again with `scope` set to the page's `AXWebArea` element.
2. Find the element that holds the text, such as an `AXStaticText` or `AXHeading`. Pick the smallest one that contains all of it.
3. `desktop_select` that element with `text` set to the exact text, and `prefix` or `suffix` if it occurs more than once. Expect `completed` with `selection` read back.
4. `desktop_key` with `key: "c"`, `modifiers: ["command"]` and the snapshot from step 3's result.
5. `desktop_clipboard_read`.

**Verify:** the clipboard text equals the requested text. If you only need the text, `desktop_read` the window instead; it changes neither the selection nor the clipboard.

**Goes wrong:**

- Text that spans several elements, such as a paragraph with a link inside, can't be selected in one call. Select within one element, or use `desktop_read`.
- A long element can be refused when the host can't find the range within its step limit. Select within a smaller element.
- `unknown` means the page's selection didn't read back as the requested range, for example because a script changed it. Inspect before retrying.
- Some pages block copying, or put other text on the clipboard. Check the clipboard.

## Edit a spreadsheet cell

`desktop_set_cell` writes cells that hold a field or a checkbox. Spreadsheet cells such as Numbers' and Excel's usually show only text and are refused, so edit them in place *(unverified: which apps expose cell controls)*.

1. inspect the window with `scope` set to the table, then `desktop_read` with `table: true` and that scope. Find the row and column.
2. `desktop_click` the cell's `AXCell` element from that inspection, a child of the row. A single click selects the cell; typing replaces its content.
3. `desktop_insert` with the value and `route: "type"`. Expect `unknown`, since nothing reads the cell during editing.
4. `desktop_key` with `key: "enter"` to commit. In Numbers and Excel, Return moves to the cell below.

**Verify:** inspect with `scope` set to the table again and `desktop_read` it. The cell shows the value as the app formats it, such as `1,000` for `1000`.

**Goes wrong:**

- A double click edits the existing content instead of replacing it.
- Typing `=` starts a formula. The app reformats values it reads as dates or numbers.
- `escape` cancels an edit that hasn't been committed.

