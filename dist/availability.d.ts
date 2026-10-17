/** Why a window can or can't be observed and acted on now. Read only: nothing here sends input or recovers. */
type WindowAvailability = {
    state: "available" | "limited" | "unavailable";
    reason: "visible" | "session_locked" | "display_asleep" | "minimized" | "app_hidden" | "other_space" | "off_screen" | "not_on_screen" | "accessibility_unavailable" | "sparse_accessibility" | "window_gone";
    /** The Space holding the window, for desktop_switch_space, when it is on another Space. */
    space_id?: number;
    /** The native observation reason when Accessibility can't see the window. */
    cause?: string;
    hint?: string;
};
/** The fields of one desktop_windows row that availability reads. */
type WindowFacts = {
    bounds?: {
        x: number;
        y: number;
        width: number;
        height: number;
    };
    is_on_screen?: boolean;
    is_minimized?: boolean;
    space_ids?: number[];
    display_index?: number | null;
    display_current_space_id?: number | null;
    display_asleep?: boolean | null;
    observation_capability?: string | null;
    observation_reason?: string | null;
};
/** The listing-wide facts of a desktop_windows result. */
type SessionFacts = {
    session_locked?: boolean;
    app_hidden?: boolean | null;
};
/** Classifies one window from its desktop_windows row, most fundamental cause first. */
export declare function windowAvailability(window: WindowFacts, session: SessionFacts): WindowAvailability;
/**
 * Classifies a failed inspection, read or action from the window's row read afterwards. A window that looks
 * available but failed with an incomplete Accessibility read has a sparse tree, as on a web view's first load.
 */
export declare function failureAvailability(message: string, window: WindowFacts | undefined, session: SessionFacts): WindowAvailability;
export {};
