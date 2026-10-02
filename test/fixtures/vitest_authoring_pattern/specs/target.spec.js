import { expect, test } from "vitest";

// The ONE test this fixture's `-t` filter is meant to select (see
// AUTHORING.md, "Scoping a `vitest -t` predicate on a multi-spec-file
// project"). other.spec.js exists so the project has more than one spec
// file, which is what makes the naive `Tests  1 passed (1)` aggregate check
// unsatisfiable.
test("passes the target case", () => {
  expect(1 + 1).toBe(2);
});
