import assert from "node:assert/strict";
import { test } from "node:test";
import { canonicalDate } from "../dist/date-value.js";

test("dates with an offset become UTC to the second", () => {
	assert.equal(canonicalDate("2026-10-17T15:30:00Z"), "2026-10-17T15:30:00Z");
	assert.equal(canonicalDate("2026-10-17T15:30+02:00"), "2026-10-17T13:30:00Z");
	assert.equal(canonicalDate("2026-10-17T01:15:05-04:30"), "2026-10-17T05:45:05Z");
});

test("dates without an offset are local", () => {
	assert.equal(canonicalDate("2026-10-17"), new Date(2026, 9, 17).toISOString().replace(/\.\d{3}Z$/, "Z"));
	assert.equal(
		canonicalDate("2026-10-17T09:05"),
		new Date(2026, 9, 17, 9, 5).toISOString().replace(/\.\d{3}Z$/, "Z"),
	);
});

test("malformed and impossible dates are refused", () => {
	for (const text of ["", "tomorrow", "2026-02-30", "2026-13-01", "2026-10-17T24:00", "2026-10-17 15:30", "17/10/2026", "2026-10-17T15:30:00.5Z"]) {
		assert.equal(canonicalDate(text), undefined, text);
	}
});
