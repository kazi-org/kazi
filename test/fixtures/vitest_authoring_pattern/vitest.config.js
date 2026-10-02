import { defineConfig } from "vitest/config";

// Two spec files under specs/ (target.spec.js + other.spec.js) is the whole
// point of this fixture: it pins AUTHORING.md's guidance on scoping a
// `vitest -t` predicate on a project with more than one spec file (github
// kazi-org/kazi#1700). Explicit `include` so that shape is deliberate, not an
// accident of vitest's own default glob.
export default defineConfig({
  test: {
    include: ["specs/**/*.spec.js"],
  },
});
