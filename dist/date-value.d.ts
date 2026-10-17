/**
 * Reads an ISO 8601 date or date-time as the UTC instant a date control stores, to the second.
 * A date alone is local midnight and a time without an offset is local, as a date picker shows them.
 */
export declare function canonicalDate(text: string): string | undefined;
