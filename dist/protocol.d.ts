export type DesktopAppTarget = {
    pid: number;
    process_start_identity_decimal: string;
};
export type DesktopWindowTarget = DesktopAppTarget & {
    window_id: number;
    bounds: {
        x: number;
        y: number;
        width: number;
        height: number;
    };
    is_minimized: boolean;
};
export type DesktopManagement = {
    op: "activate" | "hide" | "unhide";
    target: DesktopAppTarget;
} | {
    op: "quit";
    target: DesktopAppTarget;
    force?: boolean;
} | {
    op: "focus" | "minimize" | "restore" | "maximize" | "close";
    target: DesktopWindowTarget;
} | {
    op: "fullscreen";
    target: DesktopWindowTarget;
    enabled: boolean;
} | {
    op: "move";
    target: DesktopWindowTarget;
    position: {
        x: number;
        y: number;
    };
} | {
    op: "resize";
    target: DesktopWindowTarget;
    size: {
        width: number;
        height: number;
    };
};
/** Press one button by its exact title, replace one text field's value by its listed index, or choose a path in a file panel. */
export type DesktopDialogAnswer = {
    op: "dialog-answer";
    target: DesktopAppTarget | DesktopWindowTarget;
} & ({
    button: string;
} | {
    field: number;
    text: string;
} | {
    path: string;
});
/** One status item from desktop_menubar_items: owner process generation, inventory index and its window if it has one. */
export type DesktopStatusItemTarget = DesktopAppTarget & {
    index: number;
    window_id?: number;
};
export type DesktopApplication = {
    path: string;
} | {
    bundle_id: string;
};
export type DesktopLaunch = {
    op: "launch";
    application: DesktopApplication;
};
export type DesktopOpen = {
    op: "open";
    item: {
        path: string;
    } | {
        url: string;
    };
    application?: DesktopApplication;
};
/** One element ID from an earlier accessibility snapshot of the same window. */
export type DesktopScope = {
    snapshot: string;
    element: string;
};
/** The conditions desktop_wait can wait for, one per call. */
export declare const DESKTOP_WAIT_CONDITIONS: readonly ["window_appears", "window_gone", "dialog_appears", "dialog_gone", "element_appears", "element_gone", "text_changes", "text_equals", "text_contains", "app_running", "app_frontmost", "app_quit"];
export type DesktopWaitCondition = (typeof DESKTOP_WAIT_CONDITIONS)[number];
/** An element matched by its role and exact title (label), value or identifier. */
export type DesktopElementMatch = {
    role: string;
    title?: string;
    value?: string;
    identifier?: string;
};
/** A bounded, read-only wait: each poll is one ordinary read, and no input is sent. */
export type DesktopWait = {
    op: "wait";
    until: DesktopWaitCondition;
    bundle_id?: string;
    pid?: number;
    window?: number;
    title?: string;
    title_contains?: string;
    element?: DesktopElementMatch;
    scope?: DesktopScope;
    text?: string;
    timeout_ms?: number;
};
/** A desktop_wait condition an action checks after an unknown outcome; its timeout_ms is shorter. */
export type DesktopExpect = Omit<DesktopWait, "op">;
/** The actions that take expect; others opt in by joining this list and their tool's schema. */
export declare const DESKTOP_EXPECT_OPS: readonly ["click", "key", "system-key", "drag", "insert"];
/** Writes the full-resolution capture, or the part under region in global desktop points, as a PNG. */
export type DesktopCaptureSave = {
    save_path?: string;
    overwrite?: boolean;
    region?: {
        x: number;
        y: number;
        width: number;
        height: number;
    };
};
export type DesktopRequest = DesktopManagement | DesktopLaunch | DesktopOpen | DesktopDialogAnswer | {
    op: "dialog";
    target: DesktopAppTarget | DesktopWindowTarget;
} | {
    op: "clipboard-read";
    format?: "text" | "image" | "files";
} | {
    op: "clipboard-write";
    text: string;
} | {
    op: "clipboard-write";
    format: "image";
    path: string;
} | {
    op: "clipboard-write";
    format: "files";
    paths: string[];
} | {
    op: "apps";
    query?: string;
} | {
    op: "windows";
    pid: number;
} | {
    op: "menus";
    target: DesktopAppTarget;
    path?: string[];
} | {
    op: "menu";
    target: DesktopAppTarget;
    path: string[];
} | {
    op: "menubar-items";
} | {
    op: "menubar-click";
    target: DesktopStatusItemTarget;
} | {
    op: "dock";
    title?: string;
    menu_item?: string;
} | {
    op: "spaces";
} | {
    op: "switch-space";
    space_id: number;
} | ({
    op: "inspect";
    pid: number;
    window: number;
    mode?: "accessibility" | "pixels";
    ocr?: boolean;
    scope?: DesktopScope;
} & DesktopCaptureSave) | {
    op: "read";
    pid: number;
    window: number;
    scope?: DesktopScope;
    /** Reads the scope as a table of rows and cells instead of text. */
    table?: boolean;
    row_offset?: number;
    max_rows?: number;
} | DesktopWait | {
    op: "notifications";
} | {
    op: "notification-action";
    id: string;
    action: string;
} | ({
    op: "screen";
    display?: number;
    ocr?: boolean;
} & DesktopCaptureSave) | {
    op: "click";
    snapshot: string;
    element?: string;
    point?: DesktopPoint;
    kind?: DesktopClick;
    modifiers?: DesktopModifier[];
    expect?: DesktopExpect;
} | {
    op: "scroll";
    snapshot: string;
    element?: string;
    point?: DesktopPoint;
    direction: DesktopDirection;
    amount: number;
} | {
    op: "drag";
    snapshot: string;
    from: DesktopPoint;
    to: DesktopPoint;
    to_snapshot?: string;
    button?: DesktopButton;
    duration_ms?: number;
    modifiers?: DesktopModifier[];
    path?: DesktopPoint[];
    expect?: DesktopExpect;
} | {
    op: "hover";
    snapshot: string;
    element?: string;
    point?: DesktopPoint;
} | {
    op: "press";
    snapshot: string;
    element?: string;
    point?: DesktopPoint;
    button?: DesktopButton;
    duration_ms?: number;
} | {
    op: "type";
    snapshot: string;
    element: string;
    text: string;
} | {
    op: "insert";
    snapshot: string;
    text: string;
    route?: "paste" | "type";
    expect?: DesktopExpect;
} | {
    op: "element-action";
    snapshot: string;
    element: string;
    action: DesktopElementAction;
} | {
    op: "set-value";
    snapshot: string;
    element: string;
    value: number | boolean | string;
} | {
    op: "set-cell";
    pid: number;
    window: number;
    snapshot: string;
    /** The table, or the area that holds it, in the snapshot, as a table read's scope. */
    table: string;
    row: string;
    column: string | number;
    value: number | boolean | string;
} | {
    op: "select";
    snapshot: string;
    element: string;
    text: string;
    prefix?: string;
    suffix?: string;
    selection?: DesktopSelection;
} | {
    op: "key";
    snapshot: string;
    key?: DesktopKey;
    modifiers?: DesktopModifier[];
    /** Up to 16 chords pressed in order, instead of key. */
    keys?: {
        key: DesktopKey;
        modifiers?: DesktopModifier[];
    }[];
    /** Presses key this many times, up to 32. */
    repeat?: number;
    expect?: DesktopExpect;
} | {
    op: "system-key";
    key: DesktopKey | DesktopSystemKey;
    modifiers?: DesktopModifier[];
    expect?: DesktopExpect;
};
export type DesktopPoint = {
    x: number;
    y: number;
};
export declare const DESKTOP_CLICKS: readonly ["single", "double", "right", "middle", "triple"];
export declare const DESKTOP_DIRECTIONS: readonly ["up", "down", "left", "right"];
export declare const DESKTOP_BUTTONS: readonly ["left", "right"];
export type DesktopClick = (typeof DESKTOP_CLICKS)[number];
export type DesktopDirection = (typeof DESKTOP_DIRECTIONS)[number];
export type DesktopButton = (typeof DESKTOP_BUTTONS)[number];
/** Keys that type no character, named; every other key is given as the character it types. */
/** Media, volume and brightness keys, which the system rather than a window acts on. */
export declare const DESKTOP_SYSTEM_KEYS: readonly ["play_pause", "next_track", "previous_track", "volume_up", "volume_down", "mute", "brightness_up", "brightness_down", "keyboard_brightness_up", "keyboard_brightness_down"];
export declare const DESKTOP_KEYS: readonly ["enter", "tab", "escape", "backspace", "delete", "up", "down", "left", "right", "space", "home", "end", "pageup", "pagedown", "help", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "keypad0", "keypad1", "keypad2", "keypad3", "keypad4", "keypad5", "keypad6", "keypad7", "keypad8", "keypad9", "keypaddecimal", "keypadmultiply", "keypadplus", "keypadminus", "keypaddivide", "keypadequals", "keypadenter", "keypadclear"];
export declare const DESKTOP_MODIFIERS: readonly ["command", "control", "option", "shift"];
export declare const DESKTOP_SELECTIONS: readonly ["text", "cursor_before", "cursor_after"];
/** Named Accessibility actions; AXPress is desktop_click's route and is not listed separately. */
export declare const DESKTOP_ELEMENT_ACTIONS: readonly ["AXShowMenu", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel", "AXPick", "AXRaise", "AXScrollToVisible"];
export type DesktopNamedKey = (typeof DESKTOP_KEYS)[number];
export type DesktopSystemKey = (typeof DESKTOP_SYSTEM_KEYS)[number];
/** A named key, or the one printable character a key types without Shift or Option, such as `,` or `a`. */
export type DesktopKey = DesktopNamedKey | (string & {});
export type DesktopModifier = (typeof DESKTOP_MODIFIERS)[number];
export type DesktopSelection = (typeof DESKTOP_SELECTIONS)[number];
export type DesktopElementAction = (typeof DESKTOP_ELEMENT_ACTIONS)[number];
export type DesktopAction = Extract<DesktopRequest, {
    op: "click" | "type" | "key" | "system-key" | "switch-space" | "insert" | "select" | "element-action" | "set-value" | "set-cell" | "scroll" | "drag" | "hover" | "press" | "activate" | "launch" | "open" | "quit" | "close" | "focus" | "minimize" | "restore" | "move" | "resize" | "clipboard-write" | "menu" | "dialog-answer" | "hide" | "unhide" | "maximize" | "fullscreen" | "menubar-click" | "dock" | "notification-action";
}>;
export type DesktopOutcome = "completed" | "refused" | "unknown";
export type DesktopImage = {
    mimeType: string;
    data: string;
};
/** `text` is the bounded JSON shown to a model; `outcome` is set for actions. */
export type DesktopResult = {
    text: string;
    image?: DesktopImage;
    outcome?: DesktopOutcome;
    isError?: boolean;
};
export declare function isDesktopAction(request: DesktopRequest): request is DesktopAction;
export declare function isDesktopManagement(request: DesktopRequest): request is DesktopManagement;
/** Whether a key is named or is one printable, non-space character; native checks the current layout has it. */
export declare function isDesktopKey(key: unknown): key is DesktopKey;
