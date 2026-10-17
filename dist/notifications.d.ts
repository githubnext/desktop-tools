import type { DesktopRequest, DesktopResult } from "./protocol.js";
/** Notification Center's process; its banners, alerts and open panel are windows of it. */
export declare const NOTIFICATION_CENTER = "com.apple.notificationcenterui";
/** Under the 60-second request timeout common MCP clients use. */
export declare const NOTIFICATIONS_MS = 50000;
type Json = Record<string, unknown>;
export type NotificationIO = {
    /** One ordinary read: apps, windows or inspect. */
    observe(request: DesktopRequest, signal: AbortSignal): Promise<DesktopResult>;
    /** One native action request; `onDispatch` runs once input may have been sent. */
    perform(input: Json, signal: AbortSignal, onDispatch: () => void): Promise<Json>;
};
export type NotificationEntry = {
    id: string;
    pid: number;
    window_id: number;
    kind: string;
    app: string | null;
    title: string | null;
    subtitle: string | null;
    body: string | null;
    time: string | null;
    description: string | null;
    texts: string[];
    stack: boolean;
    actions: string[];
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
export {};
