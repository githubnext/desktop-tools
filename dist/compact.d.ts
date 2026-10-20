/**
 * The shape results take for a model: what an agent acts on, once.
 *
 * Native results carry detection metadata, timings, receipts the client has already checked, duplicated fields and
 * booleans spelled as strings. A model pays for all of it in every call, so results leave it out unless the client
 * is verbose. Internal reads (waits, cell edits, notifications) keep the full shape; only the final result is made
 * compact.
 */
export type CompactOptions = {
    /** List every window, including the untitled off-screen strips most apps keep, instead of counting them. */
    allWindows?: boolean;
};
export declare function compactResult(text: string, options?: CompactOptions): string;
export declare function compact(value: unknown, options?: CompactOptions, key?: string): unknown;
