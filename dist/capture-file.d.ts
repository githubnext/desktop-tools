/** A rectangle in global top-left desktop points, as window and display bounds use. */
export type DesktopRegion = {
    x: number;
    y: number;
    width: number;
    height: number;
};
export type CaptureSave = {
    save_path?: unknown;
    overwrite?: unknown;
    region?: unknown;
};
export type SavedCapture = {
    path: string;
    width: number;
    height: number;
    region: DesktopRegion | null;
};
type Run = (file: string, args: string[], signal: AbortSignal) => Promise<string>;
type Dimensions = (path: string, signal: AbortSignal) => Promise<{
    width: number;
    height: number;
}>;
/** Checks save_path, overwrite and region before anything is captured. */
export declare function validateSave(request: CaptureSave): Promise<string | undefined>;
/**
 * Writes the full-resolution capture, or the part of it under region, as a PNG at path. area is the capture's
 * extent in global desktop points; the capture's own pixels map onto it, so nothing is scaled.
 */
export declare function saveCapture(capture: string, scratch: string, path: string, request: CaptureSave, area: DesktopRegion | undefined, tools: {
    run: Run;
    dimensions: Dimensions;
}, signal: AbortSignal): Promise<SavedCapture>;
export {};
