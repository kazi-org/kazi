import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

# Run against an isolated executable; --mix-release uses the assembled release entry.
release = pathlib.Path(sys.argv[1]).resolve()
mix_release = "--mix-release" in sys.argv[2:]
root = pathlib.Path(tempfile.mkdtemp(prefix="kazi-release-smoke-"))
bin = root / "bin"
bin.mkdir()
worker = bin / "claude"
worker.write_text(
    '#!/bin/sh\nn=$(cat count 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > count\nif test "$n" = 2 && test "$SMOKE_FIX" = true; then touch fixed; fi\nif test "$n" = 1; then exit 1; fi\nexit 0\n'
)
worker.chmod(0o755)
env = dict(
    os.environ,
    PATH=str(bin) + ":" + os.environ["PATH"],
    KAZI_DB=str(root / "db.sqlite"),
    KAZI_STATE_DIR=str(root / "state"),
    KAZI_SINKS_DIR=str(root / "runs"),
    ERL_FLAGS="+S 2:2",
    KAZI_SESSION_COLLECTOR="false",
    KAZI_VELOCITY_COLLECTOR="false",
)


def cli(args, code=0):
    e = dict(env, KAZI_SMOKE_ARGS=json.dumps(args))
    command = (
        [
            str(release),
            "eval",
            'Application.put_env(:kazi, :sinks_dir, System.fetch_env!("KAZI_SINKS_DIR")); Kazi.Release.cli(Jason.decode!(System.fetch_env!("KAZI_SMOKE_ARGS")))',
        ]
        if mix_release
        else [str(release), *args]
    )
    p = subprocess.run(
        command, env=e, text=True, capture_output=True, timeout=90, check=False
    )
    (root / "last-output").write_text(p.stdout + p.stderr)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    result = next(
        json.loads(x) for x in reversed(p.stdout.splitlines()) if x.startswith("{")
    )

    assert result["schema_version"] == 2, result
    return result


print(cli(["version", "--json"]), flush=True)
for entry in ["file", "proposal"]:
    for fix in [True, False]:
        env["SMOKE_FIX"] = str(fix).lower()
        work = root / f"{entry}-{fix}"
        work.mkdir()
        payload = {
            "goal_id": f"bounded-{entry}-{fix}",
            "name": "complete repair contract",
            "predicates": [
                {
                    "id": "code",
                    "provider": "custom_script",
                    "description": "create fixed",
                    "config": {
                        "cmd": "sh",
                        "args": ["-c", "test -f fixed"],
                        "verdict": "exit_zero",
                    },
                }
            ],
            "budget": {"max_total_dispatches": 2, "max_dispatches": 1},
            "escalation": {"ladder": ["one", "two", "three"]},
            "enforcement": {"enabled": False},
        }
        if entry == "proposal":
            ref = cli(["plan", "--json", "--predicates", json.dumps(payload)])[
                "proposal_ref"
            ]
            cli(["approve", ref, "--json"])
        else:
            f = work / "goal.toml"
            f.write_text(
                'id="bounded-file"\nname="complete repair contract"\n[budget]\nmax_total_dispatches=2\nmax_dispatches=1\n[escalation]\nladder=["one","two","three"]\n[enforcement]\nenabled=false\n[[predicate]]\nid="code"\nprovider="custom_script"\ncmd="sh"\nargs=["-c","test -f fixed"]\nverdict="exit_zero"\n'
            )
            ref = str(f)
        result = cli(
            ["apply", ref, "--workspace", str(work), "--harness", "claude", "--json"],
            0 if fix else 1,
        )
        assert (work / "count").read_text().strip() == "2", result
        assert result["status"] == ("converged" if fix else "over_budget"), result
        if not fix:
            h = result["stuck_bundle"]["handoff"]
            assert h["total_dispatches"] == 2
            for key in ["contract", "verification"]:
                artifact = h[key]
                path = pathlib.Path(artifact["path"])
                assert path.is_relative_to(root)
                content = path.read_bytes()
                assert hashlib.sha256(content).hexdigest() == artifact["sha256"]
                assert artifact["status"] == "available"
            assert (
                "complete repair contract"
                in pathlib.Path(h["contract"]["path"]).read_text()
            )
        print(entry, fix, result["status"], "launches=2", flush=True)
print("PASS: 4 isolated release bounded repair scenarios", flush=True)
worker.write_text(
    "#!/bin/sh\necho launched >> launches\nif test \"$SMOKE_REPAIR\" = correct; then\ncat > app.sh <<'APP'\ncase $1 in invalid) echo error;; *) expr \"$1\" \\* 2;; esac\nAPP\nelse\necho 'exit 0' > app.sh\nfi\n"
)
for entry in ["file", "proposal"]:
    for repair in ["correct", "stub"]:
        env["SMOKE_REPAIR"] = repair
        work = root / f"integrity-{entry}-{repair}"
        work.mkdir()
        (work / "app.sh").write_text("echo 0\n")
        (work / "check.sh").write_text(
            'failures=0\ntest "$(sh app.sh 2)" = 4 || failures=$((failures+1))\ntest "$(sh app.sh 3)" = 6 || failures=$((failures+1))\ntest "$(sh app.sh invalid)" = error || failures=$((failures+1))\nif test "$failures" = 0; then echo 3 > executed-count; fi\nprintf \'{"failures":%s}\\n\' "$failures"\n'
        )
        payload = {
            "goal_id": f"integrity-{entry}-{repair}",
            "predicates": [
                {
                    "id": "behavior",
                    "provider": "custom_script",
                    "config": {
                        "cmd": "sh",
                        "args": ["check.sh"],
                        "verdict": "json",
                        "path": "$.failures",
                        "pass_when": "== 0",
                    },
                }
            ],
            "qualification": {"required_red": ["behavior"]},
            "seal": {"sealed_inputs": ["check.sh"]},
            "budget": {"max_total_dispatches": 2},
            "enforcement": {"enabled": False},
        }
        if entry == "proposal":
            ref = cli(["plan", "--json", "--predicates", json.dumps(payload)])[
                "proposal_ref"
            ]
            cli(["approve", ref, "--json"])
        else:
            f = work / "goal.toml"
            f.write_text(
                'id="integrity-file-'
                + repair
                + '"\n[budget]\nmax_total_dispatches=2\n[qualification]\nrequired_red=["behavior"]\n[seal]\nsealed_inputs=["check.sh"]\n[enforcement]\nenabled=false\n[[predicate]]\nid="behavior"\nacceptance=true\nprovider="custom_script"\ncmd="sh"\nargs=["check.sh"]\nverdict="json"\npath="$.failures"\npass_when="== 0"\n'
            )
            ref = str(f)
        r = cli(
            ["apply", ref, "--workspace", str(work), "--harness", "claude", "--json"],
            0 if repair == "correct" else 1,
        )
        assert r["qualification"]["verdicts"]["behavior"] == "fail", r
        assert (r["status"] == "converged") == (repair == "correct"), r
        if repair == "correct":
            assert (work / "executed-count").read_text().strip() == "3"
        print(entry, repair, r["status"], "behavioral-red admitted", flush=True)
print("PASS: 4 isolated release acceptance scenarios", flush=True)

# The task definition must survive the public caller-drafted proposal boundary.
worker.write_text(
    "#!/bin/sh\nset -eu\n"
    'n=$(cat count 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > count\n'
    'printf "%s" "$2" > "prompt.$n"\ntouch first\n'
    'if test "$n" -ge 2; then touch done; fi\nprintf \'{"result":"repair"}\\n\'\n'
)
for entry in ["file", "proposal"]:
    for described in [True, False]:
        work = root / f"contract-{entry}-{described}"
        work.mkdir()
        subprocess.run(["git", "init", "-q", str(work)], check=True)
        (work / "guard").write_text("kept\n")
        brief = (
            "BRIEF_START " + "required detail " * 2000 + " BRIEF_END"
            if described
            else None
        )
        predicates = [
            {
                "id": "brief",
                "provider": "custom_script",
                "description": brief,
                "cmd": "sh",
                "args": ["-c", "test -f first"],
                "verdict": "exit_zero",
            },
            {
                "id": "code",
                "provider": "custom_script",
                "description": "CODE_SENTINEL test/widget_test.exs",
                "cmd": "sh",
                "args": ["-c", "test -f done"],
                "verdict": "exit_zero",
            },
            {
                "id": "guard",
                "provider": "custom_script",
                "guard": True,
                "description": "GUARD_SENTINEL",
                "cmd": "sh",
                "args": ["-c", "test -f guard"],
                "verdict": "exit_zero",
            },
            {
                "id": "hidden",
                "provider": "custom_script",
                "held_out": True,
                "description": "HIDDEN_SENTINEL",
                "cmd": "sh",
                "args": ["-c", "true"],
                "verdict": "exit_zero",
            },
        ]
        payload = {
            "goal_id": f"contract-{entry}-{described}",
            "name": "PUBLIC_NAME_SENTINEL",
            "description": "PUBLIC_DESCRIPTION_SENTINEL",
            "scope": {
                "paths": ["reference.txt"],
                "write_paths": ["app.sh"],
                "no_integration": True,
            },
            "budget": {"max_total_dispatches": 2},
            "enforcement": {"enabled": False},
            "predicates": predicates,
        }
        if entry == "proposal":
            ref = cli(["plan", "--json", "--predicates", json.dumps(payload)])[
                "proposal_ref"
            ]
            cli(["approve", ref, "--json"])
        else:
            goal = work / "goal.toml"
            header = 'id="contract-file"\nname="PUBLIC_NAME_SENTINEL"\ndescription="PUBLIC_DESCRIPTION_SENTINEL"\nmode="create"\n[scope]\npaths=["reference.txt"]\nwrite_paths=["app.sh"]\nno_integration=true\n[budget]\nmax_total_dispatches=2\n[enforcement]\nenabled=false\n'
            goal.write_text(
                header
                + "".join(
                    "\n[[predicate]]\n"
                    + "\n".join(
                        f"{key} = {json.dumps(value)}"
                        for key, value in predicate.items()
                        if value is not None
                    )
                    + "\n"
                    for predicate in predicates
                )
            )
            ref = str(goal)
        result = cli(
            [
                "apply",
                ref,
                "--workspace",
                str(work),
                "--in-place",
                "--allow-primary-workspace",
                "--harness",
                "claude",
                "--json",
            ]
        )
        assert result["status"] == "converged", result
        assert (work / "count").read_text().strip() == "2"
        for n in [1, 2]:
            prompt = (work / f"prompt.{n}").read_text()
            for text in [
                "PUBLIC_NAME_SENTINEL",
                "PUBLIC_DESCRIPTION_SENTINEL",
                "CODE_SENTINEL",
                "test/widget_test.exs",
                "GUARD_SENTINEL",
                "test -f first",
                "test -f done",
                'Read paths: ["reference.txt"]',
                'Write paths: ["app.sh"]',
            ]:
                assert text in prompt, (entry, described, n, text)
            assert "HIDDEN_SENTINEL" not in prompt
            if brief:
                assert brief in prompt
            else:
                assert "BRIEF_START" not in prompt
            if n == 2:
                assert "fix failing predicates: code" in prompt
        print(
            entry, described, "complete contract retained over 2 launches", flush=True
        )
print("PASS: 4 isolated release dispatch-contract scenarios", flush=True)

# Accounting crosses independent executable invocations and durable SQLite rows.
# The first launch exits nonzero after reporting spend; that report still counts.
import sqlite3

first_report = {
    "modelUsage": {"fixture": {"inputTokens": 10000, "outputTokens": 42533,
                              "cacheReadInputTokens": 1300000, "cacheCreationInputTokens": 0}},
    "usage": {"input_tokens": 1277629, "output_tokens": 0,
              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
    "total_cost_usd": 2.017401,
}
second_report = {"modelUsage": {"fixture": {"inputTokens": 10, "outputTokens": 20,
                                           "cacheReadInputTokens": 50, "cacheCreationInputTokens": 20}}}
for entry in ["file", "proposal"]:
    for reported in [True, False]:
        work = root / f"accounting-{entry}-{reported}"
        work.mkdir()
        worker.write_text(
            '#!/bin/sh\nn=$(cat count 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > count\n'
            + "if test \"$n\" = 1; then\ncat <<'JSON'\n" + json.dumps(first_report)
            + "\nJSON\nexit 1\nfi\ntouch fixed\ncat <<'JSON'\n"
            + json.dumps(second_report if reported else {"result": "done"}) + "\nJSON\n"
        )
        goal_id = work.name
        predicate = {"id": "code", "provider": "custom_script", "cmd": "sh",
                     "args": ["-c", "test -f fixed"], "verdict": "exit_zero"}
        if entry == "proposal":
            payload = {"goal_id": goal_id, "predicates": [predicate],
                       "budget": {"max_total_dispatches": 2}, "enforcement": {"enabled": False}}
            ref = cli(["plan", "--json", "--predicates", json.dumps(payload)])["proposal_ref"]
            cli(["approve", ref, "--json"])
        else:
            goal = work / "goal.toml"
            goal.write_text(f'id={json.dumps(goal_id)}\n[budget]\nmax_total_dispatches=2\n[enforcement]\nenabled=false\n[[predicate]]\n'
                            + "\n".join(f"{k}={json.dumps(v)}" for k, v in predicate.items()) + "\n")
            ref = str(goal)
        result = cli(["apply", ref, "--workspace", str(work), "--harness", "claude",
                      "--model", "fixture-unpriced", "--json"])
        expected = 1352533 + (100 if reported else 0)
        assert result["status"] == "converged", result
        assert (work / "count").read_text().strip() == "2"
        assert result["budget_spent"]["tokens"] == expected, result
        assert result["economy"]["tokens"] == expected
        p = result["usage_provenance"]
        assert p["dispatches"] == 2 and p["usage_reports"] == (2 if reported else 1), p
        assert p["usage_coverage"] == ("complete" if reported else "partial"), p
        assert p["cost_coverage"] == "partial" and p["cost_reports"] == 1, p
        assert p["cost_basis"] == "harness_reported_unverified", p
        assert p["reported_cost_usd"] == 2.017401 and p["actual_cost_usd"] is None, p
        status = cli(["status", goal_id, "--json"])
        assert status["usage_provenance"] == p and status["usage"] == result["usage"], status
        [group] = cli(["economy", "--goal", goal_id, "--json"])["groups"]
        assert group["tokens"]["p50"] == expected, group
        assert group["usage_provenance"]["runs_by_cost_coverage"] == {"partial": 1}, group
        assert group["usage_provenance"]["known_reported_cost_usd"] == 2.017401, group
        with sqlite3.connect(env["KAZI_DB"]) as db:
            rows = db.execute("SELECT usage_provenance FROM runs WHERE goal_ref = ?", (goal_id,)).fetchall()
            assert len(rows) == 1 and json.loads(rows[0][0]) == p, rows
            snapshots = db.execute("SELECT usage_provenance FROM iterations WHERE goal_ref = ? ORDER BY iteration_index", (goal_id,)).fetchall()
            assert json.loads(snapshots[-1][0]) == p, snapshots
        print(entry, reported, f"accounting conserved {expected} tokens and unverified $2.017401", flush=True)
print("PASS: 4 isolated release accounting scenarios", flush=True)
