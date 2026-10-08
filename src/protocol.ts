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
	| { op: "activate"; target: DesktopAppTarget }
	| { op: "quit"; target: DesktopAppTarget }
	| { op: "focus" | "minimize" | "restore" | "close"; target: DesktopWindowTarget }
	| { op: "move"; target: DesktopWindowTarget; position: { x: number; y: number } }
	| { op: "resize"; target: DesktopWindowTarget; size: { width: number; height: number } };
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

export type DesktopRequest =
	| DesktopManagement
	| DesktopLaunch
	| DesktopOpen
	| { op: "clipboard-read"; format?: "text" | "image" | "files" }
	| { op: "clipboard-write"; text: string }
	| { op: "clipboard-write"; format: "image"; path: string }
	| { op: "clipboard-write"; format: "files"; paths: string[] }
	| { op: "apps"; query?: string }
	| { op: "windows"; pid: number }
	| { op: "menus"; target: DesktopAppTarget; path?: string[] }
	| { op: "menu"; target: DesktopAppTarget; path: string[] }
	| { op: "inspect"; pid: number; window: number; mode?: "accessibility" | "pixels" }
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
		button?: DesktopButton;
		duration_ms?: number;
	}
	| { op: "type"; snapshot: string; element: string; text: string }
	| { op: "insert"; snapshot: string; text: string }
	| {
		op: "select";
		snapshot: string;
		element: string;
		text: string;
		prefix?: string;
		suffix?: string;
		selection?: DesktopSelection;
	}
	| { op: "key"; snapshot: string; key: DesktopKey; modifiers?: DesktopModifier[] };

export type DesktopPoint = { x: number; y: number };
export const DESKTOP_CLICKS = ["single", "double", "right", "middle", "triple"] as const;
export const DESKTOP_DIRECTIONS = ["up", "down", "left", "right"] as const;
export const DESKTOP_BUTTONS = ["left", "right"] as const;
export type DesktopClick = (typeof DESKTOP_CLICKS)[number];
export type DesktopDirection = (typeof DESKTOP_DIRECTIONS)[number];
export type DesktopButton = (typeof DESKTOP_BUTTONS)[number];

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
] as const;
export const DESKTOP_MODIFIERS = ["command", "control", "option", "shift"] as const;
export const DESKTOP_SELECTIONS = ["text", "cursor_before", "cursor_after"] as const;
export type DesktopKey = (typeof DESKTOP_KEYS)[number];
export type DesktopModifier = (typeof DESKTOP_MODIFIERS)[number];
export type DesktopSelection = (typeof DESKTOP_SELECTIONS)[number];
export type DesktopAction = Extract<
	DesktopRequest,
	{
		op:
			| "click"
			| "type"
			| "key"
			| "insert"
			| "select"
			| "scroll"
			| "drag"
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
			| "menu";
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
		|| request.op === "insert" || request.op === "select" || request.op === "scroll"
		|| request.op === "drag" || request.op === "clipboard-write" || request.op === "launch"
		|| request.op === "open" || request.op === "menu"
		|| isDesktopManagement(request);
}

export function isDesktopManagement(request: DesktopRequest): request is DesktopManagement {
	return request.op === "activate" || request.op === "quit" || request.op === "focus"
		|| request.op === "minimize" || request.op === "restore" || request.op === "close"
		|| request.op === "move" || request.op === "resize";
}
