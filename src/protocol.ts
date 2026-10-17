// Runtime-neutral request and result contract: no imports, so channels and Workers can share it.

export type DesktopAppTarget = {
	pid: number;
	process_start_identity_decimal: string;
};
export type DesktopWindowTarget = DesktopAppTarget & {
	window_id: number;
	bounds: { x: number; y: number; width: number; height: number };
	is_minimized: boolean;
};
export type DesktopManagement =
	| { op: "activate" | "hide" | "unhide"; target: DesktopAppTarget }
	| { op: "quit"; target: DesktopAppTarget; force?: boolean }
	| { op: "focus" | "minimize" | "restore" | "maximize" | "close"; target: DesktopWindowTarget }
	| { op: "fullscreen"; target: DesktopWindowTarget; enabled: boolean }
	| { op: "move"; target: DesktopWindowTarget; position: { x: number; y: number } }
	| { op: "resize"; target: DesktopWindowTarget; size: { width: number; height: number } };
/** Press one button by its exact title, replace one text field's value by its listed index, or choose a path in a file panel. */
export type DesktopDialogAnswer =
	& { op: "dialog-answer"; target: DesktopAppTarget | DesktopWindowTarget }
	& ({ button: string } | { field: number; text: string } | { path: string });
/** One status item from desktop_menubar_items: owner process generation, inventory index and its window if it has one. */
export type DesktopStatusItemTarget = DesktopAppTarget & { index: number; window_id?: number };
export type DesktopApplication = { path: string } | { bundle_id: string };
export type DesktopLaunch = {
	op: "launch";
	application: DesktopApplication;
};
export type DesktopOpen = {
	op: "open";
	item: { path: string } | { url: string };
	application?: DesktopApplication;
};

/** One element ID from an earlier accessibility snapshot of the same window. */
export type DesktopScope = { snapshot: string; element: string };

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
] as const;
export type DesktopWaitCondition = (typeof DESKTOP_WAIT_CONDITIONS)[number];
/** An element matched by its role and exact title (label), value or identifier. */
export type DesktopElementMatch = { role: string; title?: string; value?: string; identifier?: string };
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

export type DesktopRequest =
	| DesktopManagement
	| DesktopLaunch
	| DesktopOpen
	| DesktopDialogAnswer
	| { op: "dialog"; target: DesktopAppTarget | DesktopWindowTarget }
	| { op: "clipboard-read"; format?: "text" | "image" | "files" }
	| { op: "clipboard-write"; text: string }
	| { op: "clipboard-write"; format: "image"; path: string }
	| { op: "clipboard-write"; format: "files"; paths: string[] }
	| { op: "apps"; query?: string }
	| { op: "windows"; pid: number }
	| { op: "menus"; target: DesktopAppTarget; path?: string[] }
	| { op: "menu"; target: DesktopAppTarget; path: string[] }
	| { op: "menubar-items" }
	| { op: "menubar-click"; target: DesktopStatusItemTarget }
	| { op: "dock"; title?: string; menu_item?: string }
	| { op: "spaces" }
	| { op: "switch-space"; space_id: number }
	| {
		op: "inspect";
		pid: number;
		window: number;
		mode?: "accessibility" | "pixels";
		ocr?: boolean;
		scope?: DesktopScope;
	}
	| { op: "read"; pid: number; window: number; scope?: DesktopScope }
	| DesktopWait
	| { op: "notifications" }
	| { op: "notification-action"; id: string; action: string }
	| { op: "screen"; display?: number; ocr?: boolean }
	| {
		op: "click";
		snapshot: string;
		element?: string;
		point?: DesktopPoint;
		kind?: DesktopClick;
	}
	| {
		op: "scroll";
		snapshot: string;
		element?: string;
		point?: DesktopPoint;
		direction: DesktopDirection;
		amount: number;
	}
	| {
		op: "drag";
		snapshot: string;
		from: DesktopPoint;
		to: DesktopPoint;
		to_snapshot?: string;
		button?: DesktopButton;
		duration_ms?: number;
		modifiers?: DesktopModifier[];
		path?: DesktopPoint[];
	}
	| { op: "hover"; snapshot: string; element?: string; point?: DesktopPoint }
	| {
		op: "press";
		snapshot: string;
		element?: string;
		point?: DesktopPoint;
		button?: DesktopButton;
		duration_ms?: number;
	}
	| { op: "type"; snapshot: string; element: string; text: string }
	| { op: "insert"; snapshot: string; text: string; route?: "paste" | "type" }
	| { op: "element-action"; snapshot: string; element: string; action: DesktopElementAction }
	| { op: "set-value"; snapshot: string; element: string; value: number | boolean }
	| {
		op: "select";
		snapshot: string;
		element: string;
		text: string;
		prefix?: string;
		suffix?: string;
		selection?: DesktopSelection;
	}
	| { op: "key"; snapshot: string; key: DesktopKey; modifiers?: DesktopModifier[] }
	| { op: "system-key"; key: DesktopKey; modifiers?: DesktopModifier[] };

export type DesktopPoint = { x: number; y: number };
export const DESKTOP_CLICKS = ["single", "double", "right", "middle", "triple"] as const;
export const DESKTOP_DIRECTIONS = ["up", "down", "left", "right"] as const;
export const DESKTOP_BUTTONS = ["left", "right"] as const;
export type DesktopClick = (typeof DESKTOP_CLICKS)[number];
export type DesktopDirection = (typeof DESKTOP_DIRECTIONS)[number];
export type DesktopButton = (typeof DESKTOP_BUTTONS)[number];

/** Keys that type no character, named; every other key is given as the character it types. */
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
] as const;
export const DESKTOP_MODIFIERS = ["command", "control", "option", "shift"] as const;
export const DESKTOP_SELECTIONS = ["text", "cursor_before", "cursor_after"] as const;
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
] as const;
export type DesktopNamedKey = (typeof DESKTOP_KEYS)[number];
/** A named key, or the one printable character a key types without Shift or Option, such as `,` or `a`. */
export type DesktopKey = DesktopNamedKey | (string & {});
export type DesktopModifier = (typeof DESKTOP_MODIFIERS)[number];
export type DesktopSelection = (typeof DESKTOP_SELECTIONS)[number];
export type DesktopElementAction = (typeof DESKTOP_ELEMENT_ACTIONS)[number];
export type DesktopAction = Extract<
	DesktopRequest,
	{
		op:
			| "click"
			| "type"
			| "key"
			| "system-key"
			| "switch-space"
			| "insert"
			| "select"
			| "element-action"
			| "set-value"
			| "scroll"
			| "drag"
			| "hover"
			| "press"
			| "activate"
			| "launch"
			| "open"
			| "quit"
			| "close"
			| "focus"
			| "minimize"
			| "restore"
			| "move"
			| "resize"
			| "clipboard-write"
			| "menu"
			| "dialog-answer"
			| "hide"
			| "unhide"
			| "maximize"
			| "fullscreen"
			| "menubar-click"
			| "dock"
			| "notification-action";
	}
>;
export type DesktopOutcome = "completed" | "refused" | "unknown";
export type DesktopImage = { mimeType: string; data: string };
/** `text` is the bounded JSON shown to a model; `outcome` is set for actions. */
export type DesktopResult = {
	text: string;
	image?: DesktopImage;
	outcome?: DesktopOutcome;
	isError?: boolean;
};

export function isDesktopAction(request: DesktopRequest): request is DesktopAction {
	return request.op === "click" || request.op === "type" || request.op === "key"
		|| request.op === "system-key" || request.op === "switch-space"
		|| request.op === "insert" || request.op === "select" || request.op === "scroll"
		|| request.op === "drag" || request.op === "hover" || request.op === "press"
		|| request.op === "clipboard-write" || request.op === "launch"
		|| request.op === "element-action" || request.op === "set-value"
		|| request.op === "open" || request.op === "menu" || request.op === "dialog-answer"
		|| request.op === "menubar-click" || request.op === "dock"
		|| request.op === "notification-action" || isDesktopManagement(request);
}

export function isDesktopManagement(request: DesktopRequest): request is DesktopManagement {
	return request.op === "activate" || request.op === "quit" || request.op === "hide"
		|| request.op === "unhide" || request.op === "focus" || request.op === "minimize"
		|| request.op === "restore" || request.op === "maximize" || request.op === "fullscreen"
		|| request.op === "close" || request.op === "move" || request.op === "resize";
}

/** Whether a key is named or is one printable, non-space character; native checks the current layout has it. */
export function isDesktopKey(key: unknown): key is DesktopKey {
	if (typeof key !== "string") return false;
	if ((DESKTOP_KEYS as readonly string[]).includes(key)) return true;
	const characters = [...key];
	return characters.length === 1 && !/[\p{C}\p{Z}]/u.test(key);
}
