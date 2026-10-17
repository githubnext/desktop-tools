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

1. `desktop_clipboard_read` first if the user's clipboard matters, because the next step replaces it.
2. `desktop_clipboard_write` with `format: "files"` and `paths: ["/Users/me/a.txt", "/Users/me/b.txt"]`. Expect `completed`.
3. `desktop_focus` the destination Finder window target. Keys are refused unless the window is the app's key window and holds its focus.
4. inspect the destination window.
5. `desktop_key` with `key: "v"` and `modifiers: ["command"]`. **Command-Option-V** moves instead of copying.

**Verify:** `ls` the destination folder in a shell, or `desktop_wait` with `until: "element_appears"` for the new item's row *(unverified: Finder's row roles differ between list, icon and column views)*.

**Goes wrong:**

- A name that already exists opens a Replace / Keep Both / Stop dialog. `desktop_wait` with `until: "dialog_appears"`, read it, and answer deliberately.
- A drag between Finder windows also copies, but its result is always `unknown`.

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

1. `desktop_apps`, and read `system.input.keyboard_layout` (`id` and `name`) as the starting point.
2. `desktop_system_key` with `key: "space"` and `modifiers: ["control"]`. That selects the previous input source; with **Option** added, it selects the next one. The result is `unknown`.
3. `desktop_apps` again, and compare `system.input.keyboard_layout.id`. Repeat step 2 until it shows the wanted layout, but stop after as many presses as there are sources.

**Verify:** `system.input.keyboard_layout.id` equals the wanted ID, such as `com.apple.keylayout.US`.

**Goes wrong:**

- `keyboard_layout` is the keyboard layout in use. An input method such as Pinyin types through an underlying layout, so the ID may not change. Check the input menu instead: in `desktop_menubar_items`, it's the item owned by `TextInputMenuAgent` *(unverified owner)*. Click it with `desktop_menubar_click`, inspect the opened menu, and pick the source by name, which is also how to choose a specific source directly.
- The shortcut can be turned off or rebound in Keyboard Shortcuts > Input Sources, or taken by Spotlight.
- `desktop_key` maps characters through the current layout, so switch before typing characters with it.

## Use the share sheet

1. `desktop_menus` with the app target and `path: ["File"]`. This shows whether **Share** is a submenu of services or a single **Share…** command.
2. With a submenu, run `desktop_menu` with `path: ["File", "Share", "Mail"]` (the service's exact title). It opens that service directly.
3. With **Share…**, run `desktop_menu` with `path: ["File", "Share…"]`. A popover with service icons opens. `created_windows` may be empty, because the popover can be hosted by another process *(unverified)*. Find it with `desktop_screen`, which lists the windows on the display front to back, then inspect that window and `desktop_click` the service.

**Verify:** the service's own window. For Mail, use `desktop_wait` with `until: "window_appears"` and `bundle_id: "com.apple.mail"`; for AirDrop, the AirDrop sheet.

**Goes wrong:**

- Apps differ in where Share lives: in **File**, in a toolbar button, or in a context menu. A toolbar Share button opens the same popover as **Share…**.
- The popover closes when focus moves elsewhere. Act on it right after opening it.

## Set volume or brightness in Control Center

1. `desktop_menubar_items`. Find the Control Center item: owner bundle ID `com.apple.controlcenter`. Pick it by owner and identifier, not by title.
2. `desktop_menubar_click` with that item's `target`. The result lists and captures the windows that opened.
3. inspect the Control Center window from step 2 with its `pid` and `window_id`. Find the **Display** or **Sound** slider *(unverified: `AXSlider`, with titles that vary by language and macOS version)*. Note its current value, which tells the range: 0 to 1 or 0 to 100.
4. `desktop_set_value` with the slider and a number in that range. Expect `completed` with the value read back.

**Verify:** the readback in step 4's result, and the slider's value in the fresh observation.

**Goes wrong:**

- Control Center closes when another app takes focus, which makes the snapshot stale. Reopen it and inspect again.
- Some modules, such as Display on a Mac with an external monitor, open a detail view first: click the module, then inspect again.

## Fill a web form end to end

1. `desktop_open` with `item: {url: "https://example.com/form"}` and optionally `application: {bundle_id: "com.apple.Safari"}`.
2. `desktop_wait` with `until: "window_appears"`, the browser's `bundle_id` and `title_contains` set to part of the page title. Then `desktop_wait` with `until: "element_appears"`, that window's `pid` and `window`, and the first field as `element: {role: "AXTextField", title: "Email"}` *(the field's label as the page exposes it)*. Its result includes an inspection `snapshot_id` with the matching element IDs.
3. If the inspection is `truncated`, inspect again with `scope` set to the page's `AXWebArea` element.
4. For each text field:
   1. `desktop_click` the field. The fresh observation reports it as focused.
   2. `desktop_type` the field with that observation's `snapshot_id` and element ID. A web field is typed into with key events, so the page sees `input` and `change`. Expect `completed`; the field is read back.
5. For a `<select>`: `desktop_click` it, then `desktop_element_action` `AXPick` on the option, or `desktop_click` it.
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
