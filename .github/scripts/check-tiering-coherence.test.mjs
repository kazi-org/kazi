// T30.5 load-bearing tests for the tiering accuracy + coherence gate. These
// prove the gate is NOT a stub: it FAILS on a planted bad model id, a planted
// un-hedged cost number, and a planted unshipped command (via the composed
// T28.4 doc-commands gate), and it PASSES on the real, current surfaces and on a
// correctly-hedged cost line.
//
// Run: `node --test .github/scripts/check-tiering-coherence.test.mjs`
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

import { scanTiering, ALLOWED_MODEL_IDS } from "./check-tiering-coherence.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");

// Write `content` to a temp file and return its path; cleaned up by the OS temp
// dir but we remove the dir explicitly at the end of each test.
function withFixture(name, content, fn) {
  const dir = mkdtempSync(join(tmpdir(), "tiering-gate-"));
  try {
    const p = join(dir, name);
    writeFileSync(p, content);
    return fn(p, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── The current, real surfaces pass (control) ───────────────────────────────
test("the real tiering surfaces pass (zero findings)", () => {
  const files = [
    join(repoRoot, "README.md"),
    join(repoRoot, "AGENTS.md"),
    join(repoRoot, "lib", "kazi", "teach", "install_skill.ex"),
    join(repoRoot, "site", "src", "pages", "index.astro"),
  ];
  const findings = scanTiering(files);
  assert.deepEqual(
    findings,
    [],
    "real surfaces should be clean; findings: " + JSON.stringify(findings, null, 2),
  );
});

test("the allow-list holds the current tiering ladder ids", () => {
  for (const id of ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"]) {
    assert.ok(ALLOWED_MODEL_IDS.has(id), `${id} must be an allowed current id`);
  }
});

// ── A planted STALE / INVENTED model id FAILS ───────────────────────────────
test("a stale model id (claude-sonnet-4-5) is rejected", () => {
  withFixture("README.md", "Grind on `claude-sonnet-4-5` then escalate.\n", (p) => {
    const findings = scanTiering([p]);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].kind, "stale-model-id");
    assert.equal(findings[0].token, "claude-sonnet-4-5");
  });
});

test("an old-generation model id (claude-3-5-sonnet-20241022) is rejected", () => {
  withFixture("AGENTS.md", "ladder uses claude-3-5-sonnet-20241022 first\n", (p) => {
    const findings = scanTiering([p]);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].kind, "stale-model-id");
    assert.equal(findings[0].token, "claude-3-5-sonnet-20241022");
  });
});

test("an invented model id (claude-opus-9-9) is rejected", () => {
  withFixture("index.astro", "<code>claude-opus-9-9</code>\n", (p) => {
    const findings = scanTiering([p]);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].token, "claude-opus-9-9");
  });
});

test("the prose word Claude and non-id claude-* tokens do not false-positive", () => {
  withFixture(
    "README.md",
    "Claude Code drives kazi; the `claude` harness and the claude-api skill apply.\n",
    (p) => {
      assert.deepEqual(scanTiering([p]), []);
    },
  );
});

// ── A planted UN-HEDGED cost NUMBER FAILS; a hedged one PASSES ───────────────
test("an un-hedged dollar cost figure is rejected", () => {
  withFixture("README.md", "Each iteration costs $0.03 on Haiku.\n", (p) => {
    const findings = scanTiering([p]);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].kind, "unhedged-cost-number");
  });
});

test("an un-hedged percent saving is rejected", () => {
  withFixture("AGENTS.md", "In-family tiering is 80% cheaper than Opus-only.\n", (p) => {
    const findings = scanTiering([p]);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].kind, "unhedged-cost-number");
  });
});

test("a hedged cost number passes (being measured)", () => {
  withFixture(
    "README.md",
    "The ~$0.03 figure is being measured by the benchmark; not yet measured.\n",
    (p) => {
      assert.deepEqual(scanTiering([p]), []);
    },
  );
});

test("shell variables ($1, $GOAL) are not mistaken for currency", () => {
  withFixture(
    "install_skill.ex",
    'goal_file="$1"\nresult=$(kazi apply "$GOAL" --workspace "$WS")\n',
    (p) => {
      assert.deepEqual(scanTiering([p]), []);
    },
  );
});

// ── Composed command gate: an unshipped command still FAILS (T28.4) ─────────
// The tiering gate composes the existing doc-commands gate for command accuracy
// rather than re-implementing it. Prove that composition is load-bearing: a
// planted `kazi frobnicate` reds the T28.4 gate (BLOCKING -> exit 1).
test("the composed doc-commands gate rejects an unshipped command", () => {
  withFixture("README.md", "Run `kazi frobnicate` to converge.\n", (p) => {
    let exitCode = 0;
    try {
      execFileSync("node", [join(here, "check-doc-commands.mjs")], {
        env: { ...process.env, KAZI_DOC_FILES: p, BLOCKING: "1" },
        stdio: "pipe",
      });
    } catch (e) {
      exitCode = e.status;
    }
    assert.equal(exitCode, 1, "doc-commands gate must fail (exit 1) on `kazi frobnicate`");
  });
});
