defmodule Kazi.Context.RepairHandoff do
  @moduledoc "Immutable task contract and measured repair identity in the existing run sink."
  alias Kazi.Redaction

  def start(goal, workspace, context) do
    base = identity(workspace)

    case context[:transcript_path] do
      path when is_binary(path) ->
        contract =
          Enum.join(
            Enum.reject(
              [
                goal.name,
                goal.description | Enum.map(Kazi.Goal.all_predicates(goal), & &1.description)
              ],
              &is_nil/1
            ),
            "\n\n"
          ) <>
            "\n\n" <> inspect(goal, limit: :infinity, printable_limit: :infinity, pretty: true)

        content = Redaction.redact(contract)
        file = Path.join(Path.dirname(path), "repair-contract.txt")

        with :ok <- File.mkdir_p(Path.dirname(file)),
             :ok <- File.write(file, content, [:exclusive]) do
          %{base: base, contract: %{path: file, sha256: hash(content), status: "available"}}
        else
          _ -> %{base: base, contract: %{path: nil, sha256: nil, status: "unavailable"}}
        end

      _ ->
        %{base: base, contract: %{path: nil, sha256: nil, status: "storage_disabled"}}
    end
  end

  def finish(initial, workspace, reason, count, failing, attempts, verification) do
    contract = validate(initial.contract)

    %{
      "base" => initial.base,
      "candidate" => identity(workspace),
      "total_dispatches" => count,
      "stop_reason" => to_string(reason),
      "failing_ids" => Enum.map(failing, &to_string/1),
      "contract" => contract,
      "verification" => store_evidence(initial.contract, verification),
      "attempts" =>
        Enum.map(attempts, fn a ->
          %{fingerprint: a.fingerprint, repeats: a.repeats, effect: a.effect}
        end)
    }
    |> then(fn handoff -> handoff |> Jason.encode!() |> Redaction.redact() |> Jason.decode!() end)
  end

  defp store_evidence(%{path: contract_path}, evidence) when is_binary(contract_path) do
    bytes =
      evidence |> inspect(limit: :infinity, printable_limit: :infinity) |> Redaction.redact()

    digest = hash(bytes)
    path = Path.join(Path.dirname(contract_path), "repair-evidence-#{digest}.txt")

    case File.write(path, bytes, [:exclusive]) do
      :ok -> %{path: path, sha256: digest, status: "available"}
      {:error, :eexist} -> validate(%{path: path, sha256: digest, status: "available"})
      _ -> %{path: nil, sha256: digest, status: "unavailable"}
    end
  end

  defp store_evidence(_, _), do: %{path: nil, sha256: nil, status: "unavailable"}

  defp validate(%{path: path, sha256: expected} = contract) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        if(hash(bytes) == expected, do: contract, else: %{contract | status: "changed"})

      _ ->
        %{contract | status: "unavailable"}
    end
  end

  defp validate(contract), do: contract

  def identity(workspace) when is_binary(workspace) do
    with {sha, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true),
         {diff, 0} <-
           System.cmd("git", ["diff", "--binary", "HEAD"], cd: workspace, stderr_to_stdout: true),
         {untracked, 0} <-
           System.cmd("git", ["ls-files", "--others", "--exclude-standard", "-z"], cd: workspace) do
      files =
        for path <- String.split(untracked, <<0>>, trim: true) do
          case File.read(Path.join(workspace, path)) do
            {:ok, bytes} -> {path, hash(bytes)}
            _ -> {path, nil}
          end
        end

      %{
        "kind" => "git",
        "commit" => String.trim(sha),
        "patch_sha256" => hash(:erlang.term_to_binary({diff, Enum.sort(files)}, [:deterministic]))
      }
    else
      _ ->
        %{
          "kind" => "non_git",
          "workspace_identity" => hash(Path.expand(workspace)),
          "commit" => nil,
          "patch_sha256" => nil
        }
    end
  rescue
    _ -> %{"kind" => "unknown", "commit" => nil, "patch_sha256" => nil}
  end

  def identity(_), do: %{"kind" => "unknown", "commit" => nil, "patch_sha256" => nil}
  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
