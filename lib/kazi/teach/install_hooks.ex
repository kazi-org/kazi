defmodule Kazi.Teach.InstallHooks do
  @moduledoc """
  Registers the session-bus delivery hooks in the Claude Code settings JSON,
  opt-in (T55.2, UC-068, ADR-0071 decisions 1/3/6) -- the sibling of
  `Kazi.Teach.InstallSkill` under the same consent contract.

  `kazi install-hooks` writes THREE hook registrations. Two are matched to the
  two moments delivery matters (ADR-0071 decision 2's binding rule: bind ONLY
  to events whose stdout reaches the session's context -- for Claude Code
  those are `SessionStart` and `UserPromptSubmit`; a `Stop` hook's output
  never reaches the next turn, so binding there would be delivery to
  nowhere). The third (T60.3, issue #1156) is exempt from that rule by
  construction rather than by exception: it only POSTS outward, so its own
  stdout is discarded and there is nothing for the binding rule to bind:

      SessionStart     -> `kazi bus hook session-start`
      UserPromptSubmit -> `kazi bus hook turn`
      Notification     -> `kazi bus hook notification`

  The registered command is a kazi SUBCOMMAND, not a script file: the payload
  logic lives in the binary (unit-testable, upgrades with `kazi` itself), and
  the settings block stays one line per event.

  This is CONSENT-FIRST (ADR-0024 decision 1, reaffirmed by ADR-0071): only
  this explicit command writes; a normal `kazi` run (apply, plan, status, any
  bus verb) NEVER touches harness config. The target directory is INJECTABLE
  (`:dir`) so tests point it at a tmp dir and never touch the real `~/.claude`.

  ## Merge, never clobber (ADR-0071 decision 3, risk R-E55-1)

  The installer edits the existing settings file STRUCTURALLY BUT MINIMALLY:
  it locates the exact byte spans to touch via a span-tracking scan of the
  (Jason-validated) JSON and splices in ONLY kazi's own entries. Every byte it
  does not own -- an operator's own hooks, keys, and even their formatting and
  whitespace -- survives BYTE-IDENTICALLY. Re-running is a no-op (the file is
  not rewritten at all when both hooks are present), and `uninstall/1` removes
  exactly the spans an install added, so uninstall-after-install restores the
  pre-install bytes exactly. kazi's entries are identified by their command
  prefix (`kazi bus hook `), never by position.

  A malformed existing settings file fails with one clear line and writes
  NOTHING -- the installer must never assume it is the only writer, and must
  never turn a broken-but-recoverable file into a clobbered one.

  ## Install targets (ADR-0071 decision 3)

  The DEFAULT target is the user-level `~/.claude/settings.json` (the hook
  no-ops instantly wherever no daemon runs, so one install covers every
  project). `:project` targets the repo's LOCAL, uncommitted
  `.claude/settings.local.json` instead. The installer NEVER writes a
  committed project settings file -- in a public repo that would publish the
  operator's internal workflow (ADR-0034).

  Harness-agnostic by profile (ADR-0071 decision 6): Claude Code is the first
  and only profile shipped.
  """

  # The default settings directory (the user-level Claude Code config). Tests
  # override `:dir` with a tmp dir so the real `~/.claude` is never touched.
  @default_dir Path.join(["~", ".claude"])

  # User-level settings file vs the project's LOCAL (uncommitted) one. The
  # committed `.claude/settings.json` of a project is deliberately NOT a
  # target (ADR-0071 decision 3 / ADR-0034).
  @user_settings_file "settings.json"
  @project_settings_file "settings.local.json"

  # kazi's entries are identified by this command prefix -- never by position
  # or by matching an exact settings shape, so a later task (T55.9) can grow
  # the command's arguments without orphaning installed entries.
  @command_prefix "kazi bus hook "

  # The three registrations (ADR-0071 decision 2; Notification added T60.3).
  # Event order here is also the order they are written into a fresh settings
  # file. Every install/uninstall code path below walks this list, so adding
  # Notification here is the ONLY change needed to cover it end to end.
  @hooks [
    {"SessionStart", "kazi bus hook session-start"},
    {"UserPromptSubmit", "kazi bus hook turn"},
    {"Notification", "kazi bus hook notification"}
  ]

  @typedoc "The result detail both verbs report back to the CLI."
  @type result :: %{
          required(:path) => Path.t(),
          required(:status) => atom(),
          optional(atom()) => term()
        }

  @doc """
  Installs kazi's two hook registrations into the target settings file.

  Opts:

    * `:dir` -- the settings DIRECTORY (default `~/.claude`, tilde-expanded).
      Tests pass a tmp dir so the real `~/.claude` is never touched.
    * `:project` -- target the project-local `settings.local.json` file name
      instead of `settings.json` (with no `:dir`, under `<cwd>/.claude`).

  Returns `{:ok, %{path: path, status: status}}` where `status` is
  `:installed` (the file was created or extended) or `:unchanged` (both hooks
  were already registered -- the file is NOT rewritten, so re-running is a
  byte-level no-op). Returns `{:error, message}` (one clear line, nothing
  written) when the existing file is not valid JSON, is not a JSON object, or
  holds a `"hooks"` value with a shape kazi cannot merge into.
  """
  @spec install(keyword()) :: {:ok, result()} | {:error, String.t()}
  def install(opts \\ []) do
    path = settings_path(opts)

    case read_settings(path) do
      :absent ->
        create_fresh(path)

      {:ok, bytes} ->
        with {:ok, root} <- parse_root(bytes, path),
             {:ok, edits} <- install_edits(bytes, root, path) do
          case edits do
            [] -> {:ok, %{path: path, status: :unchanged}}
            _ -> write(path, apply_inserts(bytes, edits), %{path: path, status: :installed})
          end
        end

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Removes exactly what `install/1` added from the target settings file.

  kazi's entries are found by their command prefix (`kazi bus hook `); every
  other key and entry is preserved byte-identically. Run immediately after a
  fresh install, this restores the pre-install bytes exactly -- including
  deleting the file when the install created it (the file's bytes still equal
  a fresh install's output, so nothing else has touched it).

  Returns `{:ok, %{path: path, status: status}}` where `status` is `:removed`
  (with `deleted: true` when the whole install-created file was deleted) or
  `:unchanged` (no kazi hooks were installed). Returns `{:error, message}`
  (nothing written) on a malformed settings file.
  """
  @spec uninstall(keyword()) :: {:ok, result()} | {:error, String.t()}
  def uninstall(opts \\ []) do
    path = settings_path(opts)

    case read_settings(path) do
      :absent ->
        {:ok, %{path: path, status: :unchanged}}

      {:ok, bytes} ->
        if bytes == fresh_settings() do
          # The file is byte-identical to what a fresh install creates, so the
          # install created it and nothing else has written to it since:
          # removing the file restores the pre-install state (absence) exactly.
          case File.rm(path) do
            :ok -> {:ok, %{path: path, status: :removed, deleted: true}}
            {:error, r} -> {:error, "could not remove #{path}: #{:file.format_error(r)}"}
          end
        else
          with {:ok, root} <- parse_root(bytes, path) do
            case uninstall_spans(bytes, root) do
              [] -> {:ok, %{path: path, status: :unchanged}}
              spans -> write(path, drop_spans(bytes, spans), %{path: path, status: :removed})
            end
          end
        end

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Resolves the target settings file path for `opts` (see `install/1`):
  `<dir>/settings.json` by default, `settings.local.json` under `:project`
  (defaulting the directory to `<cwd>/.claude` instead of `~/.claude`).
  """
  @spec settings_path(keyword()) :: Path.t()
  def settings_path(opts \\ []) do
    dir =
      cond do
        is_binary(opts[:dir]) -> Path.expand(opts[:dir])
        opts[:project] -> Path.join(File.cwd!(), ".claude")
        true -> Path.expand(@default_dir)
      end

    file = if opts[:project], do: @project_settings_file, else: @user_settings_file
    Path.join(dir, file)
  end

  @doc """
  The default install directory (`~/.claude`, tilde-expanded). Exposed so the
  CLI can report where the hooks landed on a default install.
  """
  @spec default_dir() :: Path.t()
  def default_dir, do: Path.expand(@default_dir)

  @doc """
  The exact bytes `install/1` writes when no settings file exists: a minimal,
  valid Claude Code settings object holding ONLY kazi's two hook registrations
  (one line per event, ADR-0071 decision 2). Exposed so tests and the
  uninstall path pin the same canonical form.
  """
  @spec fresh_settings() :: String.t()
  def fresh_settings do
    "{\n  \"hooks\": " <> hooks_value_text() <> "\n}\n"
  end

  @doc "The `{event, command}` registrations the installer owns (ADR-0071 d2)."
  @spec hook_commands() :: [{String.t(), String.t()}]
  def hook_commands, do: @hooks

  # ---------------------------------------------------------------------------
  # install/uninstall internals
  # ---------------------------------------------------------------------------

  defp read_settings(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_fresh(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, fresh_settings()) do
      {:ok, %{path: path, status: :installed, created: true}}
    else
      {:error, reason} ->
        {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write(path, bytes, result) do
    case File.write(path, bytes) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Validate via Jason (the authoritative malformed-JSON check), then scan the
  # SAME bytes into a span tree the splice edits are computed against. The
  # scanner may assume well-formed JSON because Jason accepted it first.
  defp parse_root(bytes, path) do
    case Jason.decode(bytes) do
      {:ok, decoded} when is_map(decoded) ->
        {root, _next} = scan_value(bytes, 0)
        {:ok, root}

      {:ok, _other} ->
        {:error, "#{path} is not a JSON object -- nothing was written"}

      {:error, _} ->
        {:error, "#{path} is not valid JSON -- fix or remove it; nothing was written"}
    end
  end

  # The insertion edits (`{position, text}`) an install needs, ordered by the
  # structural gap found: no "hooks" key at all -> ONE member insertion carrying
  # both events; a "hooks" object missing an event -> a member insertion into
  # it; an event array with no kazi entry -> an element appended to it. An
  # event that already holds a kazi entry contributes NO edit, so a full set
  # yields [] and install is a byte-level no-op.
  defp install_edits(bytes, root, path) do
    case find_member(root, "hooks") do
      nil ->
        {:ok, [insert_member(root, "hooks", hooks_value_text(), "  ")]}

      %{value: %{type: :object} = hooks_obj} ->
        event_edits(bytes, hooks_obj, path)

      %{value: _} ->
        {:error, "#{path} has a non-object \"hooks\" value -- nothing was written"}
    end
  end

  defp event_edits(bytes, hooks_obj, path) do
    Enum.reduce_while(@hooks, {:ok, []}, fn {event, command}, {:ok, acc} ->
      case find_member(hooks_obj, event) do
        nil ->
          {:cont,
           {:ok, [insert_member(hooks_obj, event, event_array_text(command), "    ") | acc]}}

        %{value: %{type: :array} = arr} ->
          if Enum.any?(arr.elements, &kazi_entry?(bytes, &1)) do
            {:cont, {:ok, acc}}
          else
            {:cont, {:ok, [append_element(arr, entry_text(command), "      ") | acc]}}
          end

        %{value: _} ->
          {:halt,
           {:error, "#{path} has a non-array \"hooks\".\"#{event}\" value -- nothing was written"}}
      end
    end)
  end

  # The removal spans (`{from, to}`) an uninstall needs. Only entries WHOLLY
  # owned by kazi (every command carries the `kazi bus hook ` prefix) are
  # removed; an event array left empty of other entries loses its whole key;
  # a "hooks" object left with no other keys is removed entirely. Each span is
  # the exact inverse of the corresponding install insertion.
  defp uninstall_spans(bytes, root) do
    case find_member(root, "hooks") do
      %{value: %{type: :object} = hooks_obj} = hooks_member ->
        classified =
          for {event, _command} <- @hooks,
              member = find_member(hooks_obj, event),
              match?(%{type: :array}, member.value),
              reduce: %{full: [], partial: []} do
            acc -> classify_event(bytes, hooks_obj, member, acc)
          end

        cond do
          classified.full == [] and classified.partial == [] ->
            []

          length(classified.full) == length(hooks_obj.members) ->
            # Every member of "hooks" is fully kazi-owned (which also means
            # there are no partial arrays left inside it): remove the whole
            # "hooks" member from the root object.
            member_spans(root, [member_index(root, hooks_member)])

          true ->
            member_spans(hooks_obj, Enum.sort(classified.full)) ++
              Enum.flat_map(classified.partial, fn {arr, indices} ->
                element_spans(arr, indices)
              end)
        end

      _ ->
        []
    end
  end

  defp classify_event(bytes, hooks_obj, member, acc) do
    arr = member.value

    kazi_indices =
      for {el, i} <- Enum.with_index(arr.elements), wholly_kazi_entry?(bytes, el), do: i

    cond do
      kazi_indices == [] ->
        acc

      length(kazi_indices) == length(arr.elements) ->
        %{acc | full: [member_index(hooks_obj, member) | acc.full]}

      true ->
        %{acc | partial: [{arr, kazi_indices} | acc.partial]}
    end
  end

  defp member_index(%{members: members}, member),
    do: Enum.find_index(members, &(&1 == member))

  # ---------------------------------------------------------------------------
  # kazi-entry recognition (by command prefix, ADR-0071 decision 2)
  # ---------------------------------------------------------------------------

  # ANY command in the entry carries the kazi prefix -> the event counts as
  # installed (install adds nothing alongside it).
  defp kazi_entry?(bytes, node),
    do: node |> node_value(bytes) |> entry_commands() |> Enum.any?(&kazi_command?/1)

  # EVERY command in the entry carries the kazi prefix (and there is at least
  # one) -> the entry is wholly kazi's and uninstall may remove it. An entry
  # mixing an operator's own command with kazi's is never removed.
  defp wholly_kazi_entry?(bytes, node) do
    commands = node |> node_value(bytes) |> entry_commands()
    commands != [] and Enum.all?(commands, &kazi_command?/1)
  end

  defp entry_commands(%{"hooks" => hooks}) when is_list(hooks) do
    for %{"command" => command} <- hooks, is_binary(command), do: command
  end

  defp entry_commands(_), do: []

  defp kazi_command?(command), do: String.starts_with?(command, @command_prefix)

  # ---------------------------------------------------------------------------
  # the text kazi writes (one line per event, ADR-0071 decision 2)
  # ---------------------------------------------------------------------------

  defp entry_text(command),
    do: ~s({ "hooks": [{ "type": "command", "command": "#{command}" }] })

  defp event_array_text(command), do: "[" <> entry_text(command) <> "]"

  defp hooks_value_text do
    inner =
      Enum.map_join(@hooks, ",\n", fn {event, command} ->
        ~s(    "#{event}": #{event_array_text(command)})
      end)

    "{\n" <> inner <> "\n  }"
  end

  # ---------------------------------------------------------------------------
  # splice edits -- insertions and their exact-inverse removals
  # ---------------------------------------------------------------------------

  # Append a `"key": value` member to an object. Non-empty object: after the
  # last member's value (`,\n<indent>...`). Empty object: right after `{`
  # (compact, no added whitespace, so the removal inverse is trivially exact).
  defp insert_member(%{members: []} = obj, key, value_text, _indent),
    do: {obj.start + 1, ~s("#{key}": #{value_text})}

  defp insert_member(%{members: members}, key, value_text, indent) do
    last = List.last(members)
    {last.value.stop, ~s(,\n#{indent}"#{key}": #{value_text})}
  end

  # Append an element to an array, same shape as insert_member/4.
  defp append_element(%{elements: []} = arr, text, _indent), do: {arr.start + 1, text}

  defp append_element(%{elements: elements}, text, indent) do
    last = List.last(elements)
    {last.stop, ",\n#{indent}" <> text}
  end

  defp apply_inserts(bytes, edits) do
    edits
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(bytes, fn {pos, text}, acc ->
      binary_part(acc, 0, pos) <> text <> binary_part(acc, pos, byte_size(acc) - pos)
    end)
  end

  # Removal spans for object members / array elements, grouped into runs of
  # consecutive indices so adjacent removals never overlap. The span shapes are
  # the exact inverses of the insertions above:
  #   * a run ending at the last item, not starting at 0: from the previous
  #     item's end through the run's last item (eats the `,` + whitespace the
  #     append inserted);
  #   * a run starting at 0 with items after it: from the first item's start
  #     through the next surviving item's start (eats the trailing `,` + ws);
  #   * the whole container: everything after the opening bracket through the
  #     last item's end (leaves any original trailing whitespace).
  defp member_spans(obj, indices) do
    items = Enum.map(obj.members, &{&1.key_start, &1.value.stop})
    removal_spans(items, indices, obj.start)
  end

  defp element_spans(arr, indices) do
    items = Enum.map(arr.elements, &{&1.start, &1.stop})
    removal_spans(items, indices, arr.start)
  end

  defp removal_spans(items, indices, container_start) do
    last_index = length(items) - 1

    for {a, b} <- runs(indices) do
      cond do
        a == 0 and b == last_index ->
          {container_start + 1, item_stop(items, b)}

        b == last_index ->
          {item_stop(items, a - 1), item_stop(items, b)}

        a == 0 ->
          {item_start(items, 0), item_start(items, b + 1)}

        true ->
          {item_stop(items, a - 1), item_stop(items, b)}
      end
    end
  end

  defp item_start(items, i), do: items |> Enum.at(i) |> elem(0)
  defp item_stop(items, i), do: items |> Enum.at(i) |> elem(1)

  # Group sorted indices into inclusive `{first, last}` runs of consecutive ints.
  defp runs(indices) do
    indices
    |> Enum.sort()
    |> Enum.reduce([], fn
      i, [{a, b} | rest] when i == b + 1 -> [{a, i} | rest]
      i, acc -> [{i, i} | acc]
    end)
    |> Enum.reverse()
  end

  defp drop_spans(bytes, spans) do
    spans
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(bytes, fn {from, to}, acc ->
      binary_part(acc, 0, from) <> binary_part(acc, to, byte_size(acc) - to)
    end)
  end

  # ---------------------------------------------------------------------------
  # span scanner -- a byte-offset walk over Jason-validated JSON
  # ---------------------------------------------------------------------------
  #
  # Nodes carry `start` (offset of the value's first byte) and `stop` (offset
  # just past its last byte); objects carry members (`key`, `key_start`,
  # `value`), arrays their element nodes. String DECODING is delegated back to
  # Jason on the raw slice, so no escape logic is duplicated here. The scanner
  # is only ever run on bytes `Jason.decode/1` already accepted, so it needs no
  # error branches of its own.

  defp scan_value(bin, i) do
    i = skip_ws(bin, i)

    case :binary.at(bin, i) do
      ?{ -> scan_object(bin, i)
      ?[ -> scan_array(bin, i)
      ?" -> scan_string(bin, i)
      _ -> scan_scalar(bin, i)
    end
  end

  defp skip_ws(bin, i) do
    if i < byte_size(bin) and :binary.at(bin, i) in [?\s, ?\t, ?\n, ?\r] do
      skip_ws(bin, i + 1)
    else
      i
    end
  end

  defp scan_object(bin, start) do
    i = skip_ws(bin, start + 1)

    if :binary.at(bin, i) == ?} do
      {%{type: :object, members: [], start: start, stop: i + 1}, i + 1}
    else
      scan_members(bin, i, start, [])
    end
  end

  defp scan_members(bin, i, start, acc) do
    key_start = skip_ws(bin, i)
    {key_node, j} = scan_string(bin, key_start)
    j = skip_ws(bin, j)
    # `j` is at the `:` separator.
    {value_node, k} = scan_value(bin, j + 1)
    member = %{key: key_node.value, key_start: key_start, value: value_node}
    k = skip_ws(bin, k)

    case :binary.at(bin, k) do
      ?, ->
        scan_members(bin, k + 1, start, [member | acc])

      ?} ->
        {%{type: :object, members: Enum.reverse([member | acc]), start: start, stop: k + 1},
         k + 1}
    end
  end

  defp scan_array(bin, start) do
    i = skip_ws(bin, start + 1)

    if :binary.at(bin, i) == ?] do
      {%{type: :array, elements: [], start: start, stop: i + 1}, i + 1}
    else
      scan_elements(bin, i, start, [])
    end
  end

  defp scan_elements(bin, i, start, acc) do
    {node, j} = scan_value(bin, i)
    j = skip_ws(bin, j)

    case :binary.at(bin, j) do
      ?, ->
        scan_elements(bin, j + 1, start, [node | acc])

      ?] ->
        {%{type: :array, elements: Enum.reverse([node | acc]), start: start, stop: j + 1}, j + 1}
    end
  end

  defp scan_string(bin, start) do
    stop = string_stop(bin, start + 1)
    raw = binary_part(bin, start, stop - start)
    {%{type: :string, value: Jason.decode!(raw), start: start, stop: stop}, stop}
  end

  defp string_stop(bin, i) do
    case :binary.at(bin, i) do
      ?\\ -> string_stop(bin, i + 2)
      ?" -> i + 1
      _ -> string_stop(bin, i + 1)
    end
  end

  defp scan_scalar(bin, start) do
    stop = scalar_stop(bin, start)
    {%{type: :scalar, start: start, stop: stop}, stop}
  end

  defp scalar_stop(bin, i) do
    if i < byte_size(bin) and :binary.at(bin, i) not in [?,, ?}, ?], ?\s, ?\t, ?\n, ?\r] do
      scalar_stop(bin, i + 1)
    else
      i
    end
  end

  # The LAST member wins on a duplicate key, matching Jason's decode semantics.
  defp find_member(%{type: :object, members: members}, key),
    do: members |> Enum.filter(&(&1.key == key)) |> List.last()

  defp node_value(node, bytes),
    do: Jason.decode!(binary_part(bytes, node.start, node.stop - node.start))
end
