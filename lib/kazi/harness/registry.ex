defmodule Kazi.Harness.Registry do
  @moduledoc """
  The built-in registry of `Kazi.Harness.Profile`s (ADR-0016): the harnesses kazi
  ships with, looked up by their stable atom id.

  `:claude` is the default harness (and the one whose behaviour every other path
  is pinned against). Further built-in harnesses (`:opencode` in T8.4, then
  `:codex`/`:antigravity`/`:claw`/`:gemini_cli`) are added here as profile DATA —
  a `command`, an argv renderer, and a parser — not as new adapter modules. A
  fully custom harness is declared in config and resolved by the resolution seam
  (T8.5) without touching this module.

  Lookup is total: an unknown id returns a tagged `{:error, {:unknown_harness, id}}`
  so the resolution seam can report a clear message instead of crashing.
  """

  alias Kazi.Harness.Profile
  alias Kazi.Harness.Profiles

  @doc """
  Fetches the built-in profile for `id`, or `{:error, {:unknown_harness, id}}`.
  """
  @spec fetch(atom()) :: {:ok, Profile.t()} | {:error, {:unknown_harness, atom()}}
  def fetch(:claude), do: {:ok, claude()}
  def fetch(:opencode), do: {:ok, opencode()}
  def fetch(:codex), do: {:ok, codex()}
  def fetch(:antigravity), do: {:ok, antigravity()}
  def fetch(:claw), do: {:ok, claw()}
  def fetch(:gemini_cli), do: {:ok, gemini_cli()}
  def fetch(id) when is_atom(id), do: {:error, {:unknown_harness, id}}

  @doc """
  Fetches the built-in profile for `id`, raising `ArgumentError` on an unknown id.
  For call sites that have already validated the id (e.g. the default `:claude`).
  """
  @spec fetch!(atom()) :: Profile.t()
  def fetch!(id) when is_atom(id) do
    case fetch(id) do
      {:ok, profile} -> profile
      {:error, {:unknown_harness, ^id}} -> raise ArgumentError, "unknown harness: #{inspect(id)}"
    end
  end

  @doc "The ids of all built-in harnesses."
  @spec ids() :: [atom()]
  def ids, do: [:claude, :opencode, :codex, :antigravity, :claw, :gemini_cli]

  # The :claude profile — the default. Its argv + parser are the canonical
  # Claude-specific boundary logic (`Kazi.Harness.Profiles.Claude`), pinned
  # byte-for-byte against the real `Kazi.Harness.ClaudeAdapter` by a golden test.
  # supported_opts are the claw-code hygiene flags (T4.8) Claude understands, the
  # per-run `:command` override (the test-stub seam), `:model` — the in-family
  # tiering selector (T19.6, ADR-0033) that points Claude at a cheaper in-family
  # model via `--model` — and the inner-harness economy flags (T36.1, ADR-0047)
  # that shrink the per-dispatch tool/MCP surface, plus the `:cli_version` the
  # economy flags' version-gated capability check reads. A Claude-only flag is
  # never forwarded to a different harness. (`:model` is also an always-kept
  # adapter opt in `Kazi.Harness`, so the model still reaches `build_args`;
  # declaring it here keeps the profile's advertised opt surface honest and
  # satisfies the ADR-0022 conformance contract.)
  @spec claude() :: Profile.t()
  defp claude do
    %Profile{
      id: :claude,
      command: "claude",
      build_args: &Profiles.Claude.build_args/2,
      parse: &Profiles.Claude.parse/1,
      supported_opts:
        [:command, :max_budget_usd, :allowed_tools, :permission_mode, :model] ++
          [
            :tools,
            :disallowed_tools,
            :mcp_config,
            :strict_mcp_config,
            :max_turns,
            :exclude_dynamic_system_prompt_sections,
            :no_session_persistence,
            # T36.6 (ADR-0047): the Claude-only reasoning-effort lever (`--effort
            # <level>`). Declared ONLY here so a non-Claude harness never receives it.
            :effort,
            :cli_version
          ]
    }
  end

  # The :opencode profile (T8.4, ADR-0016). argv is `run <prompt> --format json`
  # plus `--dir <workspace>` (T39.7: `opencode run` ignores the launch cwd, so
  # the CliAdapter-threaded workspace must be an explicit flag or the inner
  # agent edits outside the goal's workspace) and an optional `--model
  # <provider/model>`; the parser consumes opencode's NDJSON event stream
  # (`Kazi.Harness.Profiles.Opencode`). supported_opts are the per-run
  # `:command` override (the test-stub seam), `:model`, and `:workspace` —
  # opencode does NOT understand Claude's hygiene flags, so resolution (T8.5)
  # drops them.
  @spec opencode() :: Profile.t()
  defp opencode do
    %Profile{
      id: :opencode,
      command: "opencode",
      build_args: &Profiles.Opencode.build_args/2,
      parse: &Profiles.Opencode.parse/1,
      supported_opts: [:command, :model, :workspace]
    }
  end

  # The :codex profile (T14.2, ADR-0022) — OpenAI's Codex CLI, the priority
  # fully-conformant addition. argv is `exec <prompt> --json` plus an optional
  # `--model <m>`; the parser consumes Codex's JSONL event stream
  # (`Kazi.Harness.Profiles.Codex`), mirroring the opencode NDJSON path.
  # supported_opts are the per-run `:command` override (the test-stub seam) and
  # `:model` — Codex does NOT understand Claude's hygiene flags, so resolution
  # (T8.5) drops them. Auth is `OPENAI_API_KEY` / `codex login`, supplied by the
  # operator's environment (not a profile concern).
  @spec codex() :: Profile.t()
  defp codex do
    %Profile{
      id: :codex,
      command: "codex",
      build_args: &Profiles.Codex.build_args/2,
      parse: &Profiles.Codex.parse/1,
      supported_opts: [:command, :model]
    }
  end

  # The :antigravity profile (T14.3, ADR-0022) — Google's Antigravity CLI
  # (`antigravity`, also installed as `agy`), conformant WITH a workaround. The
  # bare `--prompt`/`-p` flag silently drops stdout under a non-TTY subprocess
  # (bug `google-antigravity/antigravity-cli#76`) — exactly kazi's mode — so this
  # profile sets `prompt_via: :file`: the CliAdapter writes the prompt to a temp
  # file and `build_args` renders `run --prompt-file <tmp> --output json --yes`
  # (`Kazi.Harness.Profiles.Antigravity`). The parser reads the `--output json`
  # envelope. supported_opts are the per-run `:command` override (the test-stub
  # seam) and `:model` — Antigravity does NOT understand Claude's hygiene flags,
  # so resolution (T8.5) drops them. Auth is `GEMINI_API_KEY` /
  # `ANTIGRAVITY_API_KEY`, supplied by the operator's environment (forwarded via
  # opts[:env], not a profile concern).
  @spec antigravity() :: Profile.t()
  defp antigravity do
    %Profile{
      id: :antigravity,
      command: "antigravity",
      build_args: &Profiles.Antigravity.build_args/2,
      parse: &Profiles.Antigravity.parse/1,
      supported_opts: [:command, :model],
      prompt_via: :file
    }
  end

  # The :claw profile (T14.4, ADR-0022) — claw-code, added BEST-EFFORT / DEMO-GRADE
  # only. claw does NOT meet ADR-0022's structured-output bar: it emits no
  # documented JSON, has no model flag, and is self-described as "an agent-managed
  # museum exhibit rather than a production tool." argv is the bare `prompt
  # <prompt>`; the parser surfaces the RAW stdout as `:result` with NO cost/token
  # extraction (`Kazi.Harness.Profiles.Claw`). supported_opts is just the per-run
  # `:command` override (the test-stub seam) — claw understands neither Claude's
  # hygiene flags nor a `:model`, so resolution (T8.5) drops them. Auth is via env
  # API keys (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`), supplied by the operator's
  # environment (forwarded via opts[:env], not a profile concern).
  @spec claw() :: Profile.t()
  defp claw do
    %Profile{
      id: :claw,
      command: "claw",
      build_args: &Profiles.Claw.build_args/2,
      parse: &Profiles.Claw.parse/1,
      supported_opts: [:command]
    }
  end

  # The :gemini_cli profile (T37.1, ADR-0022) — Google's Gemini CLI (`gemini`), a
  # FULLY-CONFORMANT addition like Codex (native `-o json`, no #76-style non-TTY
  # workaround). argv is `-p <prompt> -o json --approval-mode yolo` plus an
  # optional `-m <m>`; `--approval-mode yolo` auto-approves tool actions so the run
  # is non-interactive (the analogue of Antigravity's `--yes`). The parser consumes
  # gemini's `-o json` envelope (`Kazi.Harness.Profiles.GeminiCli`), mirroring the
  # Antigravity single-envelope path. supported_opts are the per-run `:command`
  # override (the test-stub seam) and `:model` — gemini does NOT understand Claude's
  # hygiene flags, so resolution (T8.5) drops them. Auth is `GEMINI_API_KEY` (or
  # Google OAuth / Vertex `GOOGLE_API_KEY`), supplied by the operator's environment
  # (forwarded via opts[:env], not a profile concern).
  @spec gemini_cli() :: Profile.t()
  defp gemini_cli do
    %Profile{
      id: :gemini_cli,
      command: "gemini",
      build_args: &Profiles.GeminiCli.build_args/2,
      parse: &Profiles.GeminiCli.parse/1,
      supported_opts: [:command, :model]
    }
  end
end
