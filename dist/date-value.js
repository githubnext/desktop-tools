const pattern = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?)?$/;
/**
 * Reads an ISO 8601 date or date-time as the UTC instant a date control stores, to the second.
 * A date alone is local midnight and a time without an offset is local, as a date picker shows them.
 */
export function canonicalDate(text) {
    const match = pattern.exec(text);
    if (!match)
        return undefined;
    const [year, month, day, hour, minute, second] = match.slice(1, 7).map((part) => Number(part ?? 0));
    const zone = match[7];
    if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59)
        return undefined;
    // Rejects days past the month's end, which Date would roll into the next month.
    const days = new Date(Date.UTC(year, month, 0)).getUTCDate();
    if (day > days)
        return undefined;
    let time;
    if (zone === undefined) {
        time = new Date(year, month - 1, day, hour, minute, second).getTime();
    }
    else {
        const offset = zone === "Z"
            ? 0
            : (zone[0] === "-" ? -1 : 1) * (Number(zone.slice(1, 3)) * 60 + Number(zone.slice(4, 6)));
        time = Date.UTC(year, month - 1, day, hour, minute, second) - offset * 60_000;
    }
    if (!Number.isFinite(time))
        return undefined;
    return new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");
}
