// Runtime-neutral request and result contract: no imports, so channels and Workers can share it.
/** The conditions desktop_wait can wait for, one per call. */
export const DESKTOP_WAIT_CONDITIONS = [
    "window_appears",
    "window_gone",
    "dialog_appears",
    "dialog_gone",
    "element_appears",
    "element_gone",
    "text_changes",
    "text_equals",
    "text_contains",
    "app_running",
    "app_frontmost",
    "app_quit",
];
/** The actions that take expect; others opt in by joining this list and their tool's schema. */
export const DESKTOP_EXPECT_OPS = ["click", "key", "system-key", "drag", "insert"];
export const DESKTOP_CLICKS = ["single", "double", "right", "middle", "triple"];
export const DESKTOP_DIRECTIONS = ["up", "down", "left", "right"];
export const DESKTOP_BUTTONS = ["left", "right"];
/** Keys that type no character, named; every other key is given as the character it types. */
/** Media, volume and brightness keys, which the system rather than a window acts on. */
export const DESKTOP_SYSTEM_KEYS = [
    "play_pause",
    "next_track",
    "previous_track",
    "volume_up",
    "volume_down",
    "mute",
    "brightness_up",
    "brightness_down",
    "keyboard_brightness_up",
    "keyboard_brightness_down",
];
export const DESKTOP_KEYS = [
    "enter",
    "tab",
    "escape",
    "backspace",
    "delete",
    "up",
    "down",
    "left",
    "right",
    "space",
    "home",
    "end",
    "pageup",
    "pagedown",
    "help",
    "f1",
    "f2",
    "f3",
    "f4",
    "f5",
    "f6",
    "f7",
    "f8",
    "f9",
    "f10",
    "f11",
    "f12",
    "f13",
    "f14",
    "f15",
    "f16",
    "f17",
    "f18",
    "f19",
    "f20",
    "keypad0",
    "keypad1",
    "keypad2",
    "keypad3",
    "keypad4",
    "keypad5",
    "keypad6",
    "keypad7",
    "keypad8",
    "keypad9",
    "keypaddecimal",
    "keypadmultiply",
    "keypadplus",
    "keypadminus",
    "keypaddivide",
    "keypadequals",
    "keypadenter",
    "keypadclear",
];
export const DESKTOP_MODIFIERS = ["command", "control", "option", "shift"];
export const DESKTOP_SELECTIONS = ["text", "cursor_before", "cursor_after"];
/** Named Accessibility actions; AXPress is desktop_click's route and is not listed separately. */
export const DESKTOP_ELEMENT_ACTIONS = [
    "AXShowMenu",
    "AXIncrement",
    "AXDecrement",
    "AXConfirm",
    "AXCancel",
    "AXPick",
    "AXRaise",
    "AXScrollToVisible",
];
export function isDesktopAction(request) {
    return request.op === "click" || request.op === "type" || request.op === "key"
        || request.op === "system-key" || request.op === "switch-space"
        || request.op === "insert" || request.op === "select" || request.op === "scroll"
        || request.op === "drag" || request.op === "hover" || request.op === "press"
        || request.op === "clipboard-write" || request.op === "launch"
        || request.op === "element-action" || request.op === "set-value" || request.op === "set-cell"
        || request.op === "open" || request.op === "menu" || request.op === "dialog-answer"
        || request.op === "menubar-click" || request.op === "dock"
        || request.op === "notification-action" || isDesktopManagement(request);
}
export function isDesktopManagement(request) {
    return request.op === "activate" || request.op === "quit" || request.op === "hide"
        || request.op === "unhide" || request.op === "focus" || request.op === "minimize"
        || request.op === "restore" || request.op === "maximize" || request.op === "fullscreen"
        || request.op === "close" || request.op === "move" || request.op === "resize";
}
/** Whether a key is named or is one printable, non-space character; native checks the current layout has it. */
export function isDesktopKey(key) {
    if (typeof key !== "string")
        return false;
    if (DESKTOP_KEYS.includes(key))
        return true;
    const characters = [...key];
    return characters.length === 1 && !/[\p{C}\p{Z}]/u.test(key);
}
