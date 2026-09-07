defmodule Kazi.Qualification do
  @moduledoc "Opt-in admission of change goals with explicitly failing behavioral checks."
  alias Kazi.{Goal, PredicateVector}

  def parse(nil, _predicates), do: {:ok, nil}

  def parse(%{"required_red" => ids} = raw, predicates) when is_list(ids) and ids != [] do
    allowed =
      for p <- predicates,
          p.acceptance? and not p.guard? and to_string(p.id) != "landed",
          do: p.id

    cond do
      Map.keys(raw) != ["required_red"] ->
        {:error, "[qualification] unknown settings"}

      not Enum.all?(ids, &(is_binary(&1) and &1 in allowed)) ->
        {:error, "qualification.required_red must name declared behavioral acceptance predicates"}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, "qualification.required_red contains duplicates"}

      true ->
        {:ok, %{required_red: ids}}
    end
  end

  def parse(_, _), do: {:error, "[qualification] requires a non-empty required_red array"}

  def admit(%Goal{qualification: nil}, vector, _workspace) do
    if PredicateVector.satisfied?(vector), do: {:error, :vacuous_goal}, else: {:ok, nil}
  end

  def admit(%Goal{qualification: %{required_red: ids}} = goal, vector, workspace) do
    verdicts =
      Map.new(ids, fn id ->
        case PredicateVector.get(vector, id) do
          nil -> {id, "missing"}
          result -> {id, to_string(result.status)}
        end
      end)

    evidence = %{
      "required_red" => ids,
      "verdicts" => verdicts,
      "baseline" => baseline(workspace),
      "evaluator_fingerprint" => fingerprint(Goal.all_predicates(goal)),
      "evidence_refs" =>
        Map.new(ids, fn id ->
          result = PredicateVector.get(vector, id)

          {id,
           if(result,
             do: result.evidence[:artifact_ref] || result.evidence["artifact_ref"],
             else: nil
           )}
        end)
    }

    if Enum.all?(verdicts, fn {_, status} -> status == "fail" end),
      do: {:ok, evidence},
      else: {:error, {:qualification_failed, evidence}}
  end

  defp fingerprint(predicates) do
    predicates
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp baseline(workspace) when is_binary(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {sha, 0} -> %{"kind" => "git", "commit" => String.trim(sha)}
      _ -> %{"kind" => "non_git", "identity" => nil}
    end
  rescue
    _ -> %{"kind" => "unknown", "identity" => nil}
  end

  defp baseline(_), do: %{"kind" => "unknown", "identity" => nil}
end
