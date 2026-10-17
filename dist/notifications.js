import { errorMessage, parseResult } from "./results.js";
/** Notification Center's process; its banners, alerts and open panel are windows of it. */
const NOTIFICATION_CENTER = "com.apple.notificationcenterui";
/** Hosts of system alerts such as permission prompts, which desktop_dialog reads and answers. */
const ALERT_HOSTS = ["com.apple.UserNotificationCenter", "com.apple.SecurityAgent"];
/** Under the 60-second request timeout common MCP clients use. */
export const NOTIFICATIONS_MS = 50_000;
const MAX_WINDOWS = 8;
const MAX_ENTRIES = 40;
const MAX_TEXTS = 8;
const MAX_TEXT = 1000;
/** Custom action names as the native client lists and accepts them. */
const MAX_ACTION = 64;
function clip(text) {
    return typeof text === "string" && text.trim() ? text.slice(0, MAX_TEXT) : null;
}
function axRole(element) {
    const attributes = (element.attributes ?? {});
    return String(attributes.role ?? element.role ?? "");
}
/** Banners, alerts and their stacks: Notification Center elements that list custom actions or its subroles. */
function isEntry(element) {
    const attributes = (element.attributes ?? {});
    return typeof attributes.customActions === "string"
        || String(attributes.subrole ?? "").startsWith("AXNotificationCenter");
}
/** Each element's index range of descendants, from the preorder list and its depth attributes. */
function subtreeEnd(elements, index) {
    const depth = Number((elements[index].attributes ?? {}).depth ?? 0);
    let end = index + 1;
    while (end < elements.length && Number((elements[end].attributes ?? {}).depth ?? 0) > depth)
        end++;
    return end;
}
/** Reads fields by text identifier where the system provides one, otherwise by position. */
function fields(texts, description) {
    const named = (pattern) => texts.find(({ identifier }) => pattern.test(identifier))?.text ?? null;
    // In the macOS 11–15 structure a notification's description starts with the posting app's name.
    const app = description?.split(",")[0]?.trim() || null;
    if (texts.some(({ identifier }) => identifier)) {
        return {
            app: named(/app/i) ?? app,
            title: named(/^title$/i) ?? named(/title/i),
            subtitle: named(/subtitle/i),
            body: named(/body|message/i),
            time: named(/date|time/i),
            fields_from: "identifiers",
        };
    }
    // In the macOS 11–15 structure a banner's texts are its title, an optional subtitle and its body.
    const values = texts.map(({ text }) => text);
    return {
        app,
        title: values[0] ?? null,
        subtitle: values.length > 2 ? values[1] : null,
        body: values.length > 1 ? values[values.length - 1] : null,
        time: null,
        fields_from: "order",
    };
}
/** The notification entries of one Notification Center window inspection. */
function entries(inspection, pid, window) {
    const elements = (inspection.ui_elements ?? []);
    const snapshot = String(inspection.snapshot_id ?? "");
    const found = [];
    for (let index = 0; index < elements.length && found.length < MAX_ENTRIES; index++) {
        const element = elements[index];
        if (!isEntry(element))
            continue;
        const end = subtreeEnd(elements, index);
        const texts = [];
        let stack = false;
        for (let inner = index + 1; inner < end; inner++) {
            const child = elements[inner];
            if (isEntry(child)) {
                // A nested entry's texts belong to that entry.
                stack = true;
                inner = subtreeEnd(elements, inner) - 1;
                continue;
            }
            if (axRole(child) !== "AXStaticText" || texts.length >= MAX_TEXTS)
                continue;
            const text = clip(child.value) ?? clip(child.label);
            if (text)
                texts.push({ text, identifier: String((child.attributes ?? {}).identifier ?? "") });
        }
        const attributes = (element.attributes ?? {});
        const description = clip(element.label);
        const custom = typeof attributes.customActions === "string"
            ? attributes.customActions.split("\n").filter(Boolean)
            : [];
        found.push({
            id: `${snapshot}/${String(element.id)}`,
            pid,
            window_id: window,
            kind: String(attributes.subrole ?? axRole(element)),
            ...fields(texts, description),
            description,
            texts: texts.map(({ text }) => text),
            stack,
            actions: ["open", ...custom.filter((name) => name !== "open")],
        });
    }
    return found;
}
/** The entries of the latest read by ID, so an action can tell whether its notification went away. */
const lastRead = new Map();
/** The running apps with exactly this bundle ID; a query keeps a long inventory from cutting them off. */
async function appsWith(io, bundle, signal) {
    const data = parseResult(await io.observe({ op: "apps", query: bundle }, signal));
    return { rows: (data.apps ?? []).filter((row) => row.bundle_id === bundle), data };
}
/** Shown windows of the apps with this bundle ID. */
async function shownWindows(io, bundle, signal) {
    const shown = [];
    for (const app of (await appsWith(io, bundle, signal)).rows) {
        const data = parseResult(await io.observe({ op: "windows", pid: app.pid }, signal));
        for (const row of (data.windows ?? [])) {
            if (row.is_on_screen === true)
                shown.push({ pid: app.pid, row });
        }
    }
    return shown;
}
/** Current banners and alerts, and the entries of an open Notification Center, each with an action ID. */
export async function readNotifications(io, signal) {
    const { rows, data: apps } = await appsWith(io, NOTIFICATION_CENTER, signal);
    const center = rows[0];
    const alerts = [];
    for (const host of ALERT_HOSTS) {
        try {
            for (const { pid, row } of await shownWindows(io, host, signal)) {
                alerts.push({ host, pid, window_id: row.window_id, title: row.window_title || null, target: row.target });
            }
        }
        catch (error) {
            signal.throwIfAborted();
            alerts.push({ host, error: errorMessage(error) });
        }
    }
    if (!center) {
        return {
            notifications: [],
            notification_center_running: false,
            inventory_completeness: apps.inventory_completeness,
            system_alerts: alerts,
        };
    }
    const pid = center.pid;
    const shown = await shownWindows(io, NOTIFICATION_CENTER, signal);
    const notifications = [];
    const errors = [];
    for (const { row } of shown.slice(0, MAX_WINDOWS)) {
        const window = row.window_id;
        try {
            const result = await io.observe({ op: "inspect", pid, window }, signal);
            const data = parseResult(result);
            if (result.isError) {
                errors.push({ window_id: window, error: data.inspection_error ?? data });
                continue;
            }
            notifications.push(...entries(data, pid, window));
            if (data.truncated === true)
                errors.push({ window_id: window, error: "The window's elements were truncated." });
        }
        catch (error) {
            signal.throwIfAborted();
            errors.push({ window_id: window, error: errorMessage(error) });
        }
    }
    lastRead.clear();
    for (const entry of notifications.slice(0, MAX_ENTRIES))
        lastRead.set(String(entry.id), entry);
    return {
        notifications: notifications.slice(0, MAX_ENTRIES),
        notification_center: {
            pid,
            shown_windows: shown.map(({ row }) => ({ window_id: row.window_id, title: row.window_title || null, bounds: row.bounds })),
            ...(shown.length > MAX_WINDOWS ? { windows_not_read: shown.length - MAX_WINDOWS } : {}),
        },
        ...(errors.length ? { errors } : {}),
        system_alerts: alerts,
    };
}
export function validateNotificationAction(request) {
    const { id, action } = request;
    if (typeof id !== "string" || id.length > 600)
        throw new Error("Pass a notification id from desktop_notifications.");
    const split = id.lastIndexOf("/");
    const snapshot = id.slice(0, split), element = id.slice(split + 1);
    if (split < 1 || !element || snapshot.length > 256 || element.length > 256) {
        throw new Error("Pass a notification id from desktop_notifications.");
    }
    if (typeof action !== "string" || !action || [...action].length > MAX_ACTION
        || /\p{Cc}/u.test(action)) {
        throw new Error("Choose open, close, or one of the notification's listed actions.");
    }
    return { snapshot, element, action };
}
/** Whether a later read still shows the entry: same window, kind and texts. */
function sameEntry(entry, other) {
    return entry.window_id === other.window_id && entry.kind === other.kind
        && JSON.stringify(entry.texts) === JSON.stringify(other.texts) && entry.description === other.description;
}
const GONE = new Set(["SNAPSHOT_NOT_FOUND", "SNAPSHOT_STALE", "ELEMENT_NOT_FOUND", "STALE_ELEMENT", "WINDOW_NOT_FOUND"]);
/**
 * Opens, closes or runs one listed action of one notification through Accessibility, then reads again: the
 * result is completed only when the notification is gone, otherwise unknown.
 */
export async function notificationAction(io, request, signal) {
    const { snapshot, element, action } = validateNotificationAction(request);
    // "open" is the default click; every other action is a custom action the snapshot listed by name.
    const name = action === "close" ? "Close" : action;
    const input = action === "open"
        ? { op: "click", snapshot, element }
        : { op: "element-action", snapshot, element, action: `AXCustomAction:${name}` };
    // Reading again here would replace the snapshot the ID names, so compare with the last read instead.
    const before = lastRead.get(request.id);
    let dispatched = false;
    let data;
    try {
        data = await io.perform(input, signal, () => {
            dispatched = true;
        });
    }
    catch (error) {
        const outcome = dispatched ? "unknown" : "refused";
        return {
            outcome,
            data: {
                outcome,
                reason: errorMessage(error),
                message: dispatched
                    ? "The notification action may have run. Read notifications again before acting further."
                    : "No input was sent.",
            },
        };
    }
    const native = data.outcome;
    if (native === "refused") {
        const code = String((data.error ?? {}).code ?? "");
        const gone = GONE.has(code) || /no longer|not in this snapshot|stale/i.test(String((data.error ?? {}).message ?? ""));
        return {
            outcome: "refused",
            data: {
                ...data,
                ...(gone ? { message: "Notification gone; read again with desktop_notifications." } : {}),
            },
        };
    }
    // Read again: the notification counts as acted on only once it is gone.
    try {
        const after = await readNotifications(io, signal);
        const remaining = (after.notifications ?? []);
        const errors = (after.errors ?? []);
        const still = before ? remaining.some((entry) => sameEntry(before, entry)) : true;
        const outcome = !still && !errors.length && native === "completed" ? "completed" : "unknown";
        return {
            outcome,
            data: {
                outcome,
                action,
                native_outcome: native,
                notification_gone: before ? !still : null,
                ...(outcome === "unknown"
                    ? {
                        message: before && still
                            ? "The notification is still shown; the action may not have taken effect, or it changed the notification. Read again before acting further."
                            : "The result could not be confirmed. Read notifications again before acting further.",
                    }
                    : {}),
                native: data,
                notifications: remaining,
            },
        };
    }
    catch (error) {
        signal.throwIfAborted();
        return {
            outcome: "unknown",
            data: {
                outcome: "unknown",
                action,
                native_outcome: native,
                observation_error: errorMessage(error),
                message: "Read notifications again before acting further; do not repeat the action blindly.",
                native: data,
            },
        };
    }
}
