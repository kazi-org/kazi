import { expect, test } from "vitest";

// Neither test here matches the `-t "passes the target case"` filter, so
// vitest collects this file (it matches `test.include`) but reports both
// tests as skipped rather than excluding the file -- the behavior AUTHORING.md
// documents.
test("does not match the filter", () => {
  expect(true).toBe(true);
});

test("also does not match the filter", () => {
  expect(true).toBe(true);
});
