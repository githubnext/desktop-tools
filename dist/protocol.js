// Runtime-neutral request and result contract: it imports only the generated tool contract, plain data, so channels and
// Workers can share it.
import { contract } from "./contract.js";
/** The conditions desktop_wait can wait for, one per call. */
export const DESKTOP_WAIT_CONDITIONS = contract.waitConditions;
/** The actions that take expect: those whose tool declares it in ContractTools.swift. */
export const DESKTOP_EXPECT_OPS = contract.tools
    .filter((tool) => "expect" in tool.parameters.properties)
    .map((tool) => tool.op);
export const DESKTOP_CLICKS = ["single", "double", "right", "middle", "triple"];
export const DESKTOP_DIRECTIONS = ["up", "down", "left", "right"];
export const DESKTOP_BUTTONS = ["left", "right"];
/** Media, volume and brightness keys, which the system rather than a window acts on. */
export const DESKTOP_SYSTEM_KEYS = contract.systemKeys;
/** Keys that type no character, named; every other key is given as the character it types. */
export const DESKTOP_KEYS = contract.keys;
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
const ACTION_OPS = new Set(contract.tools.filter((tool) => tool.action).map((tool) => tool.op));
/** Whether the request changes state, as its tool declares in ContractTools.swift. */
export function isDesktopAction(request) {
    return ACTION_OPS.has(request.op);
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
