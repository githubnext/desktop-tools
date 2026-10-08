// Runtime-neutral request and result contract: no imports, so channels and Workers can share it.
export const DESKTOP_CLICKS = ["single", "double", "right", "middle", "triple"];
export const DESKTOP_DIRECTIONS = ["up", "down", "left", "right"];
export const DESKTOP_BUTTONS = ["left", "right"];
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
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
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
];
export const DESKTOP_MODIFIERS = ["command", "control", "option", "shift"];
export const DESKTOP_SELECTIONS = ["text", "cursor_before", "cursor_after"];
export function isDesktopAction(request) {
    return request.op === "click" || request.op === "type" || request.op === "key"
        || request.op === "insert" || request.op === "select" || request.op === "scroll"
        || request.op === "drag" || request.op === "clipboard-write" || request.op === "launch"
        || request.op === "open" || request.op === "menu"
        || isDesktopManagement(request);
}
export function isDesktopManagement(request) {
    return request.op === "activate" || request.op === "quit" || request.op === "focus"
        || request.op === "minimize" || request.op === "restore" || request.op === "close"
        || request.op === "move" || request.op === "resize";
}
