import type { DesktopRequest, DesktopResult } from "./protocol.js";
import { type Json } from "./results.js";
/** Under the 60-second request timeout common MCP clients use. */
export declare const NOTIFICATIONS_MS = 50000;
export type NotificationIO = {
    /** One ordinary read: apps, windows or inspect. */
    observe(request: DesktopRequest, signal: AbortSignal): Promise<DesktopResult>;
    /** One native action request; `onDispatch` runs once input may have been sent. */
    perform(input: Json, signal: AbortSignal, onDispatch: () => void): Promise<Json>;
};
/** Current banners and alerts, and the entries of an open Notification Center, each with an action ID. */
export declare function readNotifications(io: NotificationIO, signal: AbortSignal): Promise<Json>;
export declare function validateNotificationAction(request: {
    id?: unknown;
    action?: unknown;
}): {
    snapshot: string;
    element: string;
    action: string;
};
/**
 * Opens, closes or runs one listed action of one notification through Accessibility, then reads again: the
 * result is completed only when the notification is gone, otherwise unknown.
 */
export declare function notificationAction(io: NotificationIO, request: {
    id: string;
    action: string;
}, signal: AbortSignal): Promise<{
    data: Json;
    outcome: "completed" | "refused" | "unknown";
}>;
