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
            'Kazi.Release.cli(Jason.decode!(System.fetch_env!("KAZI_SMOKE_ARGS")))',
        ]
        if mix_release
        else [str(release), *args]
    )
    p = subprocess.run(
        command, env=e, text=True, capture_output=True, timeout=90, check=False
    )
    (root / "last-output").write_text(p.stdout + p.stderr)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return next(
        json.loads(x) for x in reversed(p.stdout.splitlines()) if x.startswith("{")
    )


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
            assert pathlib.Path(h["contract"]["path"]).is_file()
            assert pathlib.Path(h["verification"]["path"]).is_file()
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
