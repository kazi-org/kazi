// T56.1 (#1242): a regression pin for the priv/examples/*.toml comment scan
// added to the T28.4 doc-commands gate. Before this fix, seven `# kazi run
// ...` comments in priv/examples/*.toml carried the removed verb silently --
// the gate only scanned .md files, so a `.toml` goal-file's own usage
// comment could rot without CI ever noticing. This proves the gate now
// catches that class on a synthetic fixture, and that it does NOT
// false-positive on ordinary prose comments that happen to start a line with
// "kazi <word>" (a real failure mode discovered while adding the scan).
//
// Run: `node --test .github/scripts/check-doc-commands.test.mjs`
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");

function withFixture(name, content, fn) {
  const dir = mkdtempSync(join(tmpdir(), "doc-commands-gate-"));
  try {
    const p = join(dir, name);
    writeFileSync(p, content);
    return fn(p, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function run(env) {
  try {
    execFileSync("node", [join(here, "check-doc-commands.mjs")], {
      env: { ...process.env, ...env },
      stdio: "pipe",
    });
    return { exitCode: 0 };
  } catch (e) {
    return { exitCode: e.status, stderr: e.stderr.toString() };
  }
}

test("the real priv/examples/*.toml corpus passes (zero findings, regression control)", () => {
  const { exitCode } = run({ KAZI_DOC_FILES: "" });
  assert.equal(exitCode, 0, "the shipped .toml examples should be clean after the T56.1 fix");
});

test("a `# kazi run ...` comment in a .toml fixture is caught (the #1242 class)", () => {
  withFixture(
    "bad.toml",
    "# Example\n#     kazi run priv/examples/deploy_target.toml --workspace fixtures/x\n",
    (p) => {
      const { exitCode, stderr } = run({ KAZI_TOML_FILES: p, KAZI_DOC_FILES: "" });
      assert.equal(exitCode, 1, "a `kazi run` comment must fail the gate");
      assert.match(stderr, /removed-command: kazi run/);
    },
  );
});

test("an unshipped verb in a .toml comment is caught too", () => {
  withFixture("bad.toml", "#     kazi frobnicate --workspace .\n", (p) => {
    const { exitCode, stderr } = run({ KAZI_TOML_FILES: p, KAZI_DOC_FILES: "" });
    assert.equal(exitCode, 1);
    assert.match(stderr, /unknown-command: kazi frobnicate/);
  });
});

test("prose comments starting with 'kazi <word>' are NOT false-flagged", () => {
  withFixture(
    "prose.toml",
    "# kazi does not ship a component-testing feature; it ships a URL and\n" +
      "# kazi lands the one-line convergence edit.\n" +
      "# kazi only DRIVING it (no doc engine in core).\n",
    (p) => {
      const { exitCode } = run({ KAZI_TOML_FILES: p, KAZI_DOC_FILES: "" });
      assert.equal(exitCode, 0, "prose mentioning kazi must not be mistaken for a command");
    },
  );
});

test("a real invocation example (verb + .toml path) still passes", () => {
  withFixture(
    "good.toml",
    "#     kazi apply priv/examples/deploy_target.toml --workspace fixtures/deploy-target\n",
    (p) => {
      const { exitCode } = run({ KAZI_TOML_FILES: p, KAZI_DOC_FILES: "" });
      assert.equal(exitCode, 0);
    },
  );
});
