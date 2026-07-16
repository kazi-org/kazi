defmodule Kazi.MCP.Server do
  @moduledoc """
  A minimal, self-describing MCP (Model Context Protocol) server for kazi
  (T16.5, ADR-0024 decision 4) — the richest teachability tier.

  ADR-0023 made kazi agent-DRIVABLE (a `--json` contract, a versioned result
  schema); ADR-0024 decision 4 promotes the MCP server to a first-class
  self-teaching surface: an MCP-speaking harness (Claude Code, or any MCP client)
  connects and drives kazi NATIVELY — no shelling out, no stdout parsing. The
  tool descriptions + input schemas ARE the teaching.

  This module is the PURE protocol core: line-delimited JSON-RPC 2.0 (the MCP
  stdio transport). The logic lives in `handle_request/2`, a total function from a
  decoded JSON-RPC request map (+ injectable opts) to a decoded JSON-RPC response
  map, so the whole protocol is unit-testable without a real stdio loop, a real
  `claude`, or the network. The `Mix.Tasks.Kazi.Mcp` task is the thin stdio
  entrypoint that boots the app and pumps `handle_request/2`.

  ## Methods

    * `initialize` — returns the protocol version, server info, and the
      `tools` capability.
    * `tools/list` — returns the kazi tools, each SELF-DESCRIBING: `name`,
      `description`, and a JSON-Schema `inputSchema`. The five tools are
      `kazi_plan`, `kazi_approve`, `kazi_apply`, `kazi_status`, and
      `kazi_list_proposed` — the `plan → approve → apply`/`status` recipe. The
      deprecated `kazi_propose`/`kazi_run` tool aliases were REMOVED in v0.6.0
      (T27.9); only the names above resolve.
    * `tools/call` — dispatches a named tool to the corresponding kazi function
      (`Kazi.Authoring.propose/2`/`approve/2`, `Kazi.Runtime.run/2`, the
      read-model status) and returns its JSON result as the tool's content.
    * any other method, or an unknown tool, is a JSON-RPC error.

  ## Result shapes

  The tool result objects mirror the committed `--json` contract under
  `docs/schemas/` (`run-result.md`, `status.md`) and carry the same
  `Kazi.CLI.Schema.schema_version/0`. The `tools/list` `inputSchema` /
  result-shape descriptions REUSE `Kazi.CLI.Schema` (T16.1) rather than
  redefining the field tables, so the MCP surface and the CLI `--json` surface
  cannot drift.

  ## Hermeticity

  Every kazi seam used here is injectable: `tools/call` forwards a caller's
  `:harness` / `:adapter_opts` into `propose`/`run`, so a test (or an offline
  client) drives a stub harness / fixture run with NO real `claude` and no
  network. Read-model reads (`status`, `list_proposed`) run against whatever
  `Kazi.Repo` the host configured (the test sandbox in tests).
  """

  alias Kazi.Authoring
  alias Kazi.Bus
  alias Kazi.CLI.Schema
  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.PredicateVector
  alias Kazi.ReadModel
  alias Kazi.Runtime

  # The MCP protocol version this server speaks. A fixed, well-known revision the
  # client echoes back on `initialize`; bumped only on a protocol-level change.
  @protocol_version "2024-11-05"

  @server_name "kazi"

  # JSON-RPC 2.0 standard error codes (the subset this server raises).
  @parse_error -32_700
  @method_not_found -32_601
  @invalid_params -32_602

  @typedoc "A decoded JSON-RPC request object (string-keyed, as `Jason.decode/1` yields)."
  @type request :: map()

  @typedoc "A decoded JSON-RPC response object, ready to `Jason.encode/1`."
  @type response :: map()

  @typedoc """
  Options threaded into `handle_request/2` and forwarded to the dispatched kazi
  function — the injection seams that keep the server hermetic:

    * `:harness` — a stub `Kazi.HarnessAdapter` module for `kazi_plan`
      (and a `kazi_apply` that drafts), so no real `claude` is spawned.
    * `:adapter_opts` — keyword opts forwarded verbatim to the harness/runtime
      (e.g. a fixture run's stub `command`, a model, a per-dispatch budget).
    * `:run_opts` — extra keyword opts merged into the `Kazi.Runtime.run/2` call
      (e.g. `await_timeout`, `persist?`, the integrate/deploy seams) so a fixture
      run stays hermetic.
  """
  @type opts :: keyword()

  @doc """
  The kazi tool definitions — the self-describing surface `tools/list` returns.

  Each entry carries a `name`, a `description` (the recipe + when to reach for
  it), and a JSON-Schema `inputSchema` describing its arguments. The result
  shapes point at the committed `docs/schemas/` contracts via `Kazi.CLI.Schema`
  (T16.1), so the tool docs and the `--json` contract stay in lockstep.

  Pure and total — exposed for tests and for the `tools/list` handler.
  """
  @spec tools() :: [map()]
  def tools do
    [
      %{
        "name" => "kazi_plan",
        "description" =>
          "Draft a prose idea into a kazi goal — a set of machine-checkable acceptance " <>
            "predicates whose conjunction means the idea is done. Step 1 of the " <>
            "plan -> approve -> apply recipe. Pass `proposal` to use caller-drafted " <>
            "predicates directly (no inner model is spawned); omit it to have kazi draft " <>
            "from the idea. Returns the proposal_ref to approve against, the drafted goal, " <>
            "and its lifecycle status (proposed).",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["idea"],
          "properties" => %{
            "idea" => %{
              "type" => "string",
              "description" => "The prose idea to draft into acceptance predicates."
            },
            "proposal" => %{
              "type" => "object",
              "description" =>
                "Caller-drafts mode (ADR-0023): a {name, predicates, rationale} payload " <>
                  "the caller already authored. When present, kazi parses + persists it " <>
                  "without spawning a harness/model."
            },
            "workspace" => %{
              "type" => "string",
              "description" => "Target workspace the harness drafts against (default \".\")."
            }
          }
        }
      },
      %{
        "name" => "kazi_approve",
        "description" =>
          "Approve a proposed goal by its proposal_ref — transitions it proposed -> approved " <>
            "and returns the runnable goal id. Step 2 of the recipe: only a proposed goal may " <>
            "be approved; an already-approved/rejected proposal is an error.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["proposal_ref"],
          "properties" => %{
            "proposal_ref" => %{
              "type" => "string",
              "description" => "The proposal's review handle (returned by kazi_plan)."
            }
          }
        }
      },
      %{
        "name" => "kazi_apply",
        "description" =>
          "Drive a goal to convergence and return the terminal result the orchestrator " <>
            "branches on. Step 3 of the recipe. Supply the goal as `goal_file` (a path to a " <>
            "goal-file) OR `goal` (an inline goal-file map). The result mirrors the committed " <>
            "run-result schema: status (converged / stuck / over_budget / error), the predicate " <>
            "vector, iterations, budget_spent, next_action, reason, release_ref.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "goal_file" => %{
              "type" => "string",
              "description" => "Path to a goal-file to load and run."
            },
            "goal" => %{
              "type" => "object",
              "description" =>
                "An inline goal-file map (string-keyed), used when goal_file is absent."
            },
            "workspace" => %{
              "type" => "string",
              "description" => "Target workspace the agent edits / predicates evaluate in."
            }
          },
          "resultSchema" => result_schema(Schema.fetch("apply"))
        }
      },
      %{
        "name" => "kazi_status",
        "description" =>
          "Read a run's or proposal's current state from the read-model (a pure read; nothing " <>
            "runs). Resolves the ref to a run (if it has recorded an iteration) or a proposal. " <>
            "The result mirrors the committed status schema: kind (run / proposal), status, and " <>
            "for a run the predicate vector, iteration index, release_ref, observed_at.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["ref"],
          "properties" => %{
            "ref" => %{
              "type" => "string",
              "description" => "A goal ref (run) or proposal_ref to report on."
            }
          },
          "resultSchema" => result_schema(Schema.fetch("status"))
        }
      },
      %{
        "name" => "kazi_list_proposed",
        "description" =>
          "List proposed goals (the review queue), newest first, optionally filtered by " <>
            "lifecycle status (proposed / approved / rejected). Returns one {proposal_ref, " <>
            "goal_id, idea, status} object per proposal.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "status" => %{
              "type" => "string",
              "enum" => ["proposed", "approved", "rejected"],
              "description" => "Filter to one lifecycle state (default: all)."
            }
          }
        }
      },
      %{
        "name" => "kazi_bus_post",
        "description" =>
          "Post a message to the session bus (ADR-0067), over a running `kazi daemon`. " <>
            "Requires `kind` and `text` (capped at 64 KiB client-side). Returns " <>
            "{ok: true} on success, or a structured error (no_daemon when no daemon is " <>
            "running -- start one with `kazi daemon start`).",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["kind", "text"],
          "properties" => %{
            "kind" => %{"type" => "string", "description" => "The message kind, e.g. \"note\"."},
            "text" => %{"type" => "string", "description" => "The message body (max 64 KiB)."},
            "topic" => %{"type" => "string", "description" => "Optional subject topic."},
            "scope" => %{
              "type" => "string",
              "description" => "\"machine\" (default) or \"project\"."
            },
            "sev" => %{"type" => "string", "description" => "Severity, default \"info\"."}
          }
        }
      },
      %{
        "name" => "kazi_bus_read",
        "description" =>
          "Pull all currently-available messages off this session's durable bus consumer " <>
            "(ADR-0067), acking them so a second read returns nothing new. Pass " <>
            "peek: true to LOOK without consuming (messages stay pending for the next " <>
            "read). To WAIT for traffic, prefer kazi_bus_watch over calling this in a " <>
            "loop. Returns {ok: true, messages: [...]}, or a structured error (no_daemon).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "peek" => %{
              "type" => "boolean",
              "description" => "true: show pending messages WITHOUT acking them (default false)."
            },
            "scope" => %{
              "type" => "string",
              "description" => "\"machine\" (default) or \"project\"."
            }
          }
        }
      },
      %{
        "name" => "kazi_bus_watch",
        "description" =>
          "BLOCK until at least one bus message arrives for this session, then consume " <>
            "and return it (ADR-0067, issue #1091) -- the no-poll-loop way to wait; do " <>
            "NOT call kazi_bus_read in a loop. Anything already pending returns " <>
            "immediately. `timeout` is in SECONDS (keep it bounded); on expiry the " <>
            "result is {ok: true, timed_out: true, messages: []} rather than an error, " <>
            "so branch on timed_out. Watching also refreshes this session's presence.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "timeout" => %{
              "type" => "number",
              "description" => "Seconds to wait before returning timed_out: true."
            },
            "scope" => %{
              "type" => "string",
              "description" => "\"machine\" (default) or \"project\"."
            }
          }
        }
      },
      %{
        "name" => "kazi_bus_who",
        "description" =>
          "List sessions that have posted presence to the bus (ADR-0067). Returns " <>
            "{ok: true, sessions: [...]}, or a structured error (no_daemon).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "scope" => %{
              "type" => "string",
              "description" => "\"machine\" (default) or \"project\"."
            }
          }
        }
      },
      %{
        "name" => "kazi_bus_tell",
        "description" =>
          "Post a message directed at one named session (ADR-0067). Requires `session` and " <>
            "`text` (capped at 64 KiB client-side). Returns {ok: true}, or a structured " <>
            "error (no_daemon).",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["session", "text"],
          "properties" => %{
            "session" => %{"type" => "string", "description" => "The target session id."},
            "text" => %{"type" => "string", "description" => "The message body (max 64 KiB)."},
            "scope" => %{
              "type" => "string",
              "description" => "\"machine\" (default) or \"project\"."
            },
            "sev" => %{"type" => "string", "description" => "Severity, default \"info\"."}
          }
        }
      }
    ]
  end

  @doc """
  The pure JSON-RPC request → response dispatcher (the testable protocol core).

  `request` is a decoded JSON-RPC object (string-keyed). `opts` carries the
  injection seams (`:harness`, `:adapter_opts`, `:run_opts`) forwarded to the
  dispatched kazi function. Returns a decoded JSON-RPC response object — a
  `"result"` envelope on success, an `"error"` envelope (with a JSON-RPC code)
  on a bad method / params / tool — echoing the request `"id"`.

  A JSON-RPC NOTIFICATION (a request with no `"id"`, e.g. `notifications/*`)
  expects NO response; `handle_request/2` returns `:no_reply` for it so the
  stdio loop writes nothing.
  """
  @spec handle_request(request(), opts()) :: response() | :no_reply
  def handle_request(request, opts \\ [])

  def handle_request(%{"method" => method} = request, opts) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    if is_nil(id) and notification?(method) do
      # A notification (no id) — dispatched for side effects, no response.
      :no_reply
    else
      dispatch(method, params, id, opts)
    end
  end

  def handle_request(request, _opts) do
    error_response(Map.get(request, "id"), @invalid_params, "not a valid JSON-RPC request")
  end

  # `notifications/initialized` and friends are fire-and-forget per the MCP spec.
  defp notification?("notifications/" <> _rest), do: true
  defp notification?(_method), do: false

  # --- method dispatch -------------------------------------------------------

  defp dispatch("initialize", _params, id, _opts) do
    result_response(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => @server_name,
        "version" => kazi_version()
      }
    })
  end

  defp dispatch("tools/list", _params, id, _opts) do
    result_response(id, %{"tools" => tools()})
  end

  defp dispatch("tools/call", params, id, opts) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case call_tool(name, arguments, opts) do
      {:ok, payload} -> result_response(id, tool_result(payload))
      {:tool_error, payload} -> result_response(id, tool_error_result(payload))
      {:error, code, message} -> error_response(id, code, message)
    end
  end

  defp dispatch(method, _params, id, _opts) do
    error_response(id, @method_not_found, "unknown method: #{inspect(method)}")
  end

  # --- tool dispatch ---------------------------------------------------------

  # Each clause dispatches a self-describing tool to its kazi function and shapes
  # the JSON result. Returns `{:ok, payload}` for a successful call, `{:tool_error,
  # payload}` for a kazi-level failure surfaced AS a tool result (a JSON error
  # object the client can branch on, not a protocol error), or `{:error, code,
  # message}` for an unknown tool / bad params (a JSON-RPC protocol error).
  @spec call_tool(term(), map(), opts()) ::
          {:ok, map()} | {:tool_error, map()} | {:error, integer(), String.t()}
  defp call_tool("kazi_plan", args, opts) do
    case fetch_string(args, "idea") do
      {:ok, idea} ->
        propose_opts =
          opts
          |> Keyword.take([:harness, :adapter_opts])
          |> maybe_put_opt(:workspace, Map.get(args, "workspace"))
          |> maybe_put_opt(:proposal, Map.get(args, "proposal"))

        case Authoring.propose(idea, propose_opts) do
          {:ok, draft} -> {:ok, propose_result(draft)}
          {:error, reason} -> {:tool_error, kazi_error("propose", reason)}
        end

      :error ->
        {:error, @invalid_params, "kazi_plan requires a non-empty string `idea`"}
    end
  end

  defp call_tool("kazi_approve", args, _opts) do
    case fetch_string(args, "proposal_ref") do
      {:ok, ref} ->
        case Authoring.approve(ref) do
          {:ok, %Goal{} = goal} -> {:ok, approve_result(ref, goal)}
          {:error, reason} -> {:tool_error, kazi_error("approve", reason)}
        end

      :error ->
        {:error, @invalid_params, "kazi_approve requires a non-empty string `proposal_ref`"}
    end
  end

  defp call_tool("kazi_apply", args, opts) do
    with {:ok, goal} <- load_goal(args) do
      run_opts =
        opts
        |> Keyword.take([:harness, :adapter_opts])
        |> Keyword.merge(Keyword.get(opts, :run_opts, []))
        |> maybe_put_opt(:workspace, Map.get(args, "workspace"))

      case Runtime.run(goal, run_opts) do
        {:ok, result} -> {:ok, run_result(goal, result)}
        {:error, reason} -> {:tool_error, run_error(goal, reason)}
      end
    end
  end

  defp call_tool("kazi_status", args, _opts) do
    case fetch_string(args, "ref") do
      {:ok, ref} -> {:ok, status_result(ref)}
      :error -> {:error, @invalid_params, "kazi_status requires a non-empty string `ref`"}
    end
  end

  defp call_tool("kazi_list_proposed", args, _opts) do
    list_opts =
      case Map.get(args, "status") do
        status when is_binary(status) and status != "" -> [status: status]
        _ -> []
      end

    proposals = ReadModel.list_proposed_goals(list_opts)
    {:ok, list_proposed_result(proposals)}
  end

  defp call_tool("kazi_bus_post", args, opts) do
    with {:ok, kind} <- fetch_string_or(args, "kind", "kazi_bus_post requires `kind`"),
         {:ok, text} <- fetch_string_or(args, "text", "kazi_bus_post requires `text`") do
      case Bus.post(kind, text, bus_opts(args, opts)) do
        :ok -> {:ok, %{"schema_version" => Schema.schema_version(), "ok" => true}}
        {:error, reason} -> {:tool_error, bus_error(reason)}
      end
    end
  end

  defp call_tool("kazi_bus_read", args, opts) do
    bus_opts = bus_opts(args, opts)

    result =
      if Map.get(args, "peek") == true, do: Bus.peek(bus_opts), else: Bus.read(bus_opts)

    case result do
      {:ok, messages} ->
        {:ok,
         %{"schema_version" => Schema.schema_version(), "ok" => true, "messages" => messages}}

      {:error, reason} ->
        {:tool_error, bus_error(reason)}
    end
  end

  # A watch expiring is an expected outcome the agent branches on, not a fault:
  # timed_out: true with an empty message list, never isError.
  defp call_tool("kazi_bus_watch", args, opts) do
    watch_opts =
      bus_opts(args, opts)
      |> maybe_put_opt(:timeout, watch_timeout(Map.get(args, "timeout")))

    case Bus.watch(watch_opts) do
      {:ok, messages} ->
        {:ok,
         %{"schema_version" => Schema.schema_version(), "ok" => true, "messages" => messages}}

      {:error, :watch_timeout} ->
        {:ok,
         %{
           "schema_version" => Schema.schema_version(),
           "ok" => true,
           "timed_out" => true,
           "messages" => []
         }}

      {:error, reason} ->
        {:tool_error, bus_error(reason)}
    end
  end

  defp call_tool("kazi_bus_who", args, opts) do
    case Bus.who(bus_opts(args, opts)) do
      {:ok, sessions} ->
        {:ok,
         %{"schema_version" => Schema.schema_version(), "ok" => true, "sessions" => sessions}}

      {:error, reason} ->
        {:tool_error, bus_error(reason)}
    end
  end

  defp call_tool("kazi_bus_tell", args, opts) do
    with {:ok, session} <- fetch_string_or(args, "session", "kazi_bus_tell requires `session`"),
         {:ok, text} <- fetch_string_or(args, "text", "kazi_bus_tell requires `text`") do
      case Bus.tell(session, text, bus_opts(args, opts)) do
        :ok -> {:ok, %{"schema_version" => Schema.schema_version(), "ok" => true}}
        {:error, reason} -> {:tool_error, bus_error(reason)}
      end
    end
  end

  defp call_tool(name, _args, _opts) do
    {:error, @method_not_found, "unknown tool: #{inspect(name)}"}
  end

  defp watch_timeout(seconds) when is_number(seconds) and seconds > 0, do: trunc(seconds)
  defp watch_timeout(_), do: nil

  # The bus tools' `opts` -- scope/topic/sev from the tool arguments, plus any
  # test-only seams (`:conn`, `:sock_path`) a caller injected via `opts` (mirrors
  # the `:harness`/`:adapter_opts` seams `kazi_plan`/`kazi_apply` take).
  defp bus_opts(args, opts) do
    opts
    |> Keyword.take([:conn, :sock_path])
    |> maybe_put_opt(:scope, Map.get(args, "scope"))
    |> maybe_put_opt(:topic, Map.get(args, "topic"))
    |> maybe_put_opt(:sev, Map.get(args, "sev"))
  end

  defp bus_error(:no_daemon) do
    %{
      "schema_version" => Schema.schema_version(),
      "status" => "error",
      "error" => "no daemon running -- start one with `kazi daemon start`",
      "reason" => "no_daemon"
    }
  end

  defp bus_error({:text_too_large, cap}) do
    %{
      "schema_version" => Schema.schema_version(),
      "status" => "error",
      "error" => "message exceeds the #{cap}-byte bus cap",
      "reason" => "text_too_large"
    }
  end

  defp bus_error(reason) do
    %{
      "schema_version" => Schema.schema_version(),
      "status" => "error",
      "error" => "bus error: #{inspect(reason)}",
      "reason" => reason_string(reason)
    }
  end

  # --- goal loading (kazi_apply) ---------------------------------------------

  # Resolve the run target: a `goal_file` path is loaded through the same loader
  # the CLI uses; an inline `goal` map is rehydrated through `from_map/1`. A
  # missing/unloadable goal is a JSON-RPC invalid-params error (the call never
  # reached the runtime).
  defp load_goal(args) do
    cond do
      is_binary(path = Map.get(args, "goal_file")) and path != "" ->
        case Loader.load(path) do
          {:ok, %Goal{} = goal} ->
            {:ok, goal}

          {:error, reason} ->
            {:error, @invalid_params, "could not load goal_file: #{inspect(reason)}"}
        end

      is_map(map = Map.get(args, "goal")) ->
        case Loader.from_map(map) do
          {:ok, %Goal{} = goal} -> {:ok, goal}
          {:error, reason} -> {:error, @invalid_params, "invalid goal map: #{inspect(reason)}"}
        end

      true ->
        {:error, @invalid_params, "kazi_apply requires `goal_file` (a path) or `goal` (a map)"}
    end
  end

  # --- result shaping --------------------------------------------------------
  #
  # These mirror the committed `--json` contract under `docs/schemas/` so the MCP
  # tool result and the CLI `--json` result are the SAME object shape (the
  # `Kazi.CLI.Schema` descriptors document both). Kept here rather than reused
  # from the private CLI builders so this task touches no `lib/kazi/cli.ex`.

  defp propose_result(draft) do
    %{
      "schema_version" => Schema.schema_version(),
      "proposal_ref" => draft.proposal_ref,
      "goal_id" => to_string(draft.goal.id),
      "status" => Atom.to_string(draft.status),
      "predicates" => predicate_ids(draft.goal)
    }
  end

  defp approve_result(ref, %Goal{} = goal) do
    %{
      "schema_version" => Schema.schema_version(),
      "proposal_ref" => ref,
      "status" => "approved",
      "goal_id" => to_string(goal.id),
      "mode" => Atom.to_string(goal.mode)
    }
  end

  # The run terminal result — the committed run-result schema (docs/schemas/run-result.md).
  defp run_result(%Goal{id: id}, result) do
    status = run_status(result)

    %{
      "schema_version" => Schema.schema_version(),
      "goal_id" => to_string(id),
      "status" => status,
      "predicates" => vector_json(Map.get(result, :vector)),
      "iterations" => Map.get(result, :iterations, 0),
      "budget_spent" => %{
        "iterations" => Map.get(result, :iterations, 0),
        "exceeded" => budget_exceeded(result),
        # ADR-0046: the single rolled-up token total stays for back-compat; the
        # cached-vs-fresh split moves into the additive `usage` envelope.
        "tokens" => Map.get(result, :tokens_used, 0)
      },
      "next_action" => next_action(status),
      "reason" => reason_string(Map.get(result, :reason)),
      "release_ref" => Map.get(result, :release_ref)
    }
    |> put_usage(result)
    |> put_economy(id, status, result)
  end

  # ADR-0046 economy envelope: attach the additive `usage` object only when the
  # harness reported at least one component, mirroring the CLI's `run_result_json`
  # so the MCP tool result and the CLI `--json` result stay the SAME shape.
  defp put_usage(map, result) do
    case Kazi.CLI.Usage.render(Map.get(result, :usage, %{})) do
      usage when map_size(usage) == 0 -> map
      usage -> Map.put(map, "usage", stringify_keys(usage))
    end
  end

  # T34.6 (ADR-0046 §5): attach the additive `economy` KPIs, mirroring the CLI's
  # `run_result_json` so the MCP and `--json` results stay the SAME shape. The
  # cache + re-discovery KPIs fold over the RECORDED per-iteration counters
  # (best-effort: an unavailable read-model yields the run-aggregate KPIs only).
  # Unavailable KPIs are OMITTED by `Kazi.Economy.KPIs.to_json/1` (absent ≠ zero).
  defp put_economy(map, goal_id, status, result) do
    iterations =
      try do
        ReadModel.list_iterations(goal_id)
      rescue
        _ -> []
      end

    meta = %{
      status: status,
      converged_predicates: converged_predicate_count(Map.get(result, :vector)),
      iteration_count: Map.get(result, :iterations, 0),
      usage: Map.get(result, :usage, %{})
    }

    Map.put(
      map,
      "economy",
      Kazi.Economy.KPIs.from_iterations(iterations, meta) |> Kazi.Economy.KPIs.to_json()
    )
  end

  defp converged_predicate_count(%Kazi.PredicateVector{results: results}) do
    Enum.count(results, fn {_id, result} -> Kazi.PredicateResult.passed?(result) end)
  end

  defp converged_predicate_count(_), do: nil

  # The `usage` envelope keys are the `Kazi.CLI.Usage` field atoms; render them as
  # strings so the MCP result object is uniformly string-keyed.
  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # A pre-loop run failure (vacuous goal, unknown provider/harness, await
  # timeout): the SAME envelope shape with `status: "error"`, mirroring the CLI's
  # `run_error_json`.
  defp run_error(%Goal{id: id}, reason) do
    %{
      "schema_version" => Schema.schema_version(),
      "goal_id" => to_string(id),
      "status" => "error",
      "error" => describe_reason(reason),
      "reason" => reason_string(reason),
      "next_action" => "investigate"
    }
  end

  # The status read — the committed status schema (docs/schemas/status.md). Resolves
  # the ref to a run (it has a recorded iteration) or a proposal, exactly as the
  # CLI's `execute_status` does; an unresolved ref is a structured not-found object.
  defp status_result(ref) do
    cond do
      (iteration = ReadModel.latest_iteration(ref)) != nil ->
        vector = ReadModel.to_predicate_vector(iteration)

        %{
          "schema_version" => Schema.schema_version(),
          "kind" => "run",
          "ref" => to_string(ref),
          "status" => if(iteration.converged, do: "converged", else: "in_progress"),
          "converged" => iteration.converged,
          "iteration" => iteration.iteration_index,
          "predicates" => vector_json(vector),
          "release_ref" => iteration.release_ref,
          "observed_at" => status_timestamp(iteration.observed_at)
        }

      (proposal = ReadModel.get_proposed_goal(ref)) != nil ->
        %{
          "schema_version" => Schema.schema_version(),
          "kind" => "proposal",
          "ref" => proposal.proposal_ref,
          "status" => proposal.status,
          "goal_id" => proposal.goal_id,
          "idea" => proposal.idea
        }

      true ->
        %{
          "schema_version" => Schema.schema_version(),
          "kind" => "not_found",
          "ref" => to_string(ref),
          "error" => "no run or proposal found for ref #{inspect(ref)}"
        }
    end
  end

  defp list_proposed_result(proposals) do
    %{
      "schema_version" => Schema.schema_version(),
      "proposals" =>
        Enum.map(proposals, fn p ->
          %{
            "proposal_ref" => p.proposal_ref,
            "goal_id" => p.goal_id,
            "idea" => p.idea,
            "status" => p.status
          }
        end)
    }
  end

  # --- result-shaping helpers (mirror the CLI's --json builders) -------------

  defp run_status(%{outcome: :converged}), do: "converged"
  defp run_status(%{outcome: :over_budget}), do: "over_budget"
  defp run_status(%{outcome: :stopped}), do: "stuck"
  defp run_status(_), do: "stuck"

  defp next_action("converged"), do: "done"
  defp next_action("over_budget"), do: "raise_budget"
  defp next_action(_), do: "investigate"

  defp budget_exceeded(%{outcome: :over_budget, reason: reason}), do: reason_string(reason)
  defp budget_exceeded(_result), do: nil

  defp vector_json(nil), do: []

  defp vector_json(%PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map(fn {id, result} ->
      %{"id" => to_string(id), "verdict" => to_string(result.status)}
    end)
  end

  defp predicate_ids(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.map(fn p -> %{"id" => to_string(p.id), "provider" => Atom.to_string(p.kind)} end)
  end

  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: to_string(reason)
  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason), do: inspect(reason)

  defp status_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp status_timestamp(other), do: other

  # A kazi-level failure as a tool-result error object (the client branches on it).
  defp kazi_error(op, reason) do
    %{
      "schema_version" => Schema.schema_version(),
      "status" => "error",
      "operation" => op,
      "error" => describe_reason(reason),
      "reason" => reason_string(reason)
    }
  end

  defp describe_reason(:empty_idea), do: "the idea was blank"
  defp describe_reason(:not_found), do: "no proposal found for that proposal_ref"

  defp describe_reason(:vacuous_goal),
    do: "the goal is vacuous (every predicate already passes at t0)"

  defp describe_reason({:invalid_transition, from, to}), do: "invalid transition #{from} -> #{to}"
  defp describe_reason({:invalid_proposal, why}), do: "invalid proposal: #{why}"
  defp describe_reason({:invalid_goal, why}), do: "invalid goal: #{inspect(why)}"
  defp describe_reason({:harness_failed, why}), do: "harness failed: #{inspect(why)}"
  defp describe_reason(%Ecto.Changeset{}), do: "the proposal could not be persisted"
  defp describe_reason(reason), do: inspect(reason)

  # The result-shape descriptor (from `Kazi.CLI.Schema`) attached to a tool, so the
  # tool documents what its result object looks like alongside its inputSchema. A
  # missing schema (shouldn't happen for run/status) degrades to nil.
  defp result_schema({:ok, schema}), do: schema
  defp result_schema(:error), do: nil

  # --- JSON-RPC envelopes ----------------------------------------------------

  defp result_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  # An MCP `tools/call` result envelope: the JSON result rendered as a single text
  # content block (the MCP content shape), with the structured object also under
  # `structuredContent` so an MCP client can consume it without re-parsing text.
  defp tool_result(payload) do
    %{
      "content" => [%{"type" => "text", "text" => encode(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  # A kazi-level error surfaced as a tool result with `isError: true` — the MCP
  # convention for a tool that ran but failed, distinct from a protocol error.
  defp tool_error_result(payload) do
    %{
      "content" => [%{"type" => "text", "text" => encode(payload)}],
      "structuredContent" => payload,
      "isError" => true
    }
  end

  defp encode(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload)
    end
  end

  # --- small helpers ---------------------------------------------------------

  defp fetch_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_string_or(args, key, message) do
    case fetch_string(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, @invalid_params, message}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp kazi_version do
    case :application.get_key(:kazi, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "0.0.0"
    end
  end

  # --- stdio transport (thin) ------------------------------------------------

  @doc """
  Runs the line-delimited JSON-RPC stdio loop until EOF (the MCP stdio
  transport). Reads one JSON-RPC request per line from `device` (default
  `:stdio`), pumps `handle_request/2`, and writes each response as one JSON line
  to `:stdio`. A notification (no response) writes nothing; a line that is not
  valid JSON is answered with a JSON-RPC parse error.

  This is the ONLY impure part of the server — kept deliberately thin so the
  protocol logic stays in the pure, unit-tested `handle_request/2`. `opts` are
  forwarded to every `handle_request/2` (the injection seams).
  """
  @spec serve(keyword()) :: :ok
  def serve(opts \\ []) do
    {device, handle_opts} = Keyword.pop(opts, :device, :stdio)
    loop(device, handle_opts)
  end

  defp loop(device, opts) do
    case IO.read(device, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line
        |> String.trim()
        |> process_line(opts)
        |> emit_response()

        loop(device, opts)
    end
  end

  # A blank keep-alive line is ignored; otherwise decode and dispatch. A decode
  # failure is a JSON-RPC parse error (-32700) with a null id.
  defp process_line("", _opts), do: :no_reply

  defp process_line(line, opts) do
    case Jason.decode(line) do
      {:ok, request} -> handle_request(request, opts)
      {:error, _} -> error_response(nil, @parse_error, "parse error: invalid JSON")
    end
  end

  defp emit_response(:no_reply), do: :ok

  defp emit_response(response) do
    IO.puts(encode(response))
  end
end
