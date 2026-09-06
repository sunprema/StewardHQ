defmodule Steward.Console.Activity do
  @moduledoc """
  Durable saga history for the console (docs/agent_interaction_ux.md view 1,
  "the core 'what did the agent do' view").

  Unlike `Steward.Console.LiveState`, everything here is real: sagas and
  saga steps are Ash resources backed by Postgres, and every MCP tool call
  produces exactly one saga row and one step row through
  `Steward.SagaExecutor.execute/2`. No new instrumentation is needed, which
  is why `agent_interaction_ux.md` puts this view first in build order.

  Sagas survive restarts; the live state does not. The console must keep
  that distinction visible (§4 principle 2), so history reads come from
  here and live reads come from `LiveState`.
  """

  require Ash.Query

  alias Steward.Sagas.Saga
  alias Steward.Sagas.SagaStep

  @doc """
  Sagas newest-first, with steps loaded.

  Options mirror the filters §6.2 asks for at list level:

    * `:status`      — one status atom, or `:any`
    * `:resource`    — match a resource type touched by any step
    * `:resource_id` — match an exact resource id
    * `:has_errors`  — only sagas with at least one failed step
    * `:since`       — only sagas started after this `DateTime`
    * `:query`       — free-text match on saga id, resource id or action
    * `:sort`        — `:started` (default, newest first) or `:duration`
    * `:limit`       — defaults to 100
  """
  def list_sagas(opts \\ []) do
    query =
      Saga
      |> Ash.Query.new()
      |> Ash.Query.load(:steps)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 100))
      |> then(fn q ->
        case Keyword.get(opts, :status, :any) do
          :any -> q
          nil -> q
          status -> Ash.Query.filter(q, status == ^status)
        end
      end)
      |> then(fn q ->
        case Keyword.get(opts, :since) do
          nil -> q
          %DateTime{} = since -> Ash.Query.filter(q, inserted_at >= ^since)
        end
      end)
      |> Ash.Query.sort(inserted_at: :desc)

    query
    |> Ash.read!()
    |> Enum.map(&decorate/1)
    |> post_filter(opts)
    |> sort_rows(Keyword.get(opts, :sort, :started))
  end

  @doc "One saga with its steps, or nil."
  def get_saga(id) do
    case Ash.get(Saga, id, load: [:steps]) do
      {:ok, saga} -> decorate(saga)
      {:error, _} -> nil
    end
  end

  @doc "One step of a saga by its `step_id`, or nil."
  def get_step(saga_id, step_id) do
    case get_saga(saga_id) do
      nil -> nil
      saga -> Enum.find(saga.steps_ordered, &(&1.step_id == step_id))
    end
  end

  @doc """
  The most recent completions and failures, for the overview activity strip
  (§6.1). Running sagas are excluded — the strip reports outcomes.
  """
  def recent(limit \\ 4) do
    Saga
    |> Ash.Query.new()
    |> Ash.Query.load(:steps)
    |> Ash.Query.filter(status in [:completed, :failed, :dead_letter])
    |> Ash.Query.sort(finished_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.map(&decorate/1)
  end

  @doc """
  Error counts by reason over a window, for the overview mini-chart and the
  errors screen summary (§6.1, §6.7). Historical errors come from steps;
  live counts are what the planned telemetry would add.
  """
  def error_counts(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -3600, :second)

    SagaStep
    |> Ash.Query.new()
    |> Ash.Query.filter(status == :failed)
    |> Ash.Query.filter(inserted_at >= ^since)
    |> Ash.read!()
    |> Enum.map(&reason_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_reason, count} -> -count end)
  end

  @doc "Counts for the overview tiles that come from durable history."
  def summary do
    midnight = %{DateTime.utc_now() | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    running =
      Saga
      |> Ash.Query.new()
      |> Ash.Query.filter(status == :running)
      |> Ash.count!()

    completed_today =
      Saga
      |> Ash.Query.new()
      |> Ash.Query.filter(status == :completed)
      |> Ash.Query.filter(finished_at >= ^midnight)
      |> Ash.count!()

    dead_letter =
      Saga
      |> Ash.Query.new()
      |> Ash.Query.filter(status == :dead_letter)
      |> Ash.Query.load(:steps)
      |> Ash.read!()
      |> Enum.map(&decorate/1)

    %{running: running, completed_today: completed_today, dead_letter: dead_letter}
  end

  # ------------------------------------------------------------------
  # Decoration — everything the screens need that the row alone lacks
  # ------------------------------------------------------------------

  # Adds ordered steps, the step-status breakdown, resource types touched,
  # the tool name and a duration. §6.2 notes agent name on a saga is
  # planned; until then the tool name stands in, derived from the plan.
  defp decorate(saga) do
    steps = ordered_steps(saga)

    counts = %{
      total: length(steps),
      succeeded: Enum.count(steps, &(&1.status == :succeeded)),
      failed: Enum.count(steps, &(&1.status == :failed)),
      undone: Enum.count(steps, &(&1.status == :undone)),
      pending: Enum.count(steps, &(&1.status == :pending))
    }

    # A plain map, not the Ash struct with extra keys bolted on: the screens
    # only read, and a struct carrying fields its schema does not declare is
    # a trap for anything that later tries to write it back.
    %{
      id: saga.id,
      status: saga.status,
      attempts: saga.attempts,
      plan: saga.plan,
      error: saga.error,
      inserted_at: saga.inserted_at,
      finished_at: saga.finished_at,
      steps_ordered: steps,
      step_counts: counts,
      resources: resources_touched(saga, steps),
      tool: tool_name(saga, steps),
      duration_ms: duration_ms(saga),
      error_reason: saga_reason(saga)
    }
  end

  # Execution order: follow the plan, since `step_id` is the plan's own id.
  # Compensation runs in reverse, so undone steps are returned after the
  # forward steps and in reverse plan order — §6.2 asks for the undo order
  # to read distinctly.
  defp ordered_steps(saga) do
    steps = List.wrap(loaded_steps(saga))
    order = plan_order(saga)

    rank = fn step ->
      Map.get(order, step.step_id, length(order) + 1)
    end

    {undone, forward} = Enum.split_with(steps, &(&1.status == :undone))

    Enum.sort_by(forward, rank) ++ Enum.sort_by(undone, rank, :desc)
  end

  defp loaded_steps(%{steps: steps}) when is_list(steps), do: steps
  defp loaded_steps(_), do: []

  defp plan_order(%{plan: plan}) when is_list(plan) do
    plan
    |> Enum.with_index()
    |> Map.new(fn {step, index} -> {field(step, "id"), index} end)
  end

  defp plan_order(_), do: %{}

  defp resources_touched(saga, steps) do
    from_steps = Enum.map(steps, & &1.resource)

    from_plan =
      case saga.plan do
        plan when is_list(plan) -> Enum.map(plan, &field(&1, "resource"))
        _ -> []
      end

    (from_steps ++ from_plan)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&short_resource/1)
    |> Enum.uniq()
  end

  # The plan's first action, which is the MCP tool the agent called.
  defp tool_name(saga, steps) do
    from_plan =
      case saga.plan do
        [first | _] -> field(first, "action")
        _ -> nil
      end

    from_plan || (steps |> List.first() |> then(&(&1 && &1.action)))
  end

  defp duration_ms(%{inserted_at: start, finished_at: nil}) when not is_nil(start),
    do: DateTime.diff(DateTime.utc_now(), start, :millisecond)

  defp duration_ms(%{inserted_at: start, finished_at: finish})
       when not is_nil(start) and not is_nil(finish),
       do: DateTime.diff(finish, start, :millisecond)

  defp duration_ms(_), do: nil

  # ------------------------------------------------------------------
  # Error reasons
  # ------------------------------------------------------------------

  @doc """
  The bare error reason for a step, as one of the fixed words in
  ux_requirements.md §3.

  `Steward.Sagas.StepRunner` persists `%{reason: inspect(reason)}`, so what
  comes back out of jsonb is a string like `":stale_resource"` or
  `"{:stale_resource, %{...}}"`. Both forms reduce to `stale_resource`.
  """
  def reason_of(%{error: error}), do: reason_of(error)
  def reason_of(nil), do: nil

  def reason_of(error) when is_map(error) do
    error
    |> field("reason")
    |> parse_reason()
  end

  def reason_of(_), do: nil

  defp parse_reason(nil), do: nil

  defp parse_reason(value) when is_binary(value) do
    case Regex.run(~r/^\{?\s*:?"?([a-z_][a-zA-Z0-9_]*)/, value) do
      [_, reason] -> reason
      _ -> value
    end
  end

  defp parse_reason(value) when is_atom(value), do: to_string(value)
  defp parse_reason(_), do: nil

  defp saga_reason(%{error: error}) when is_map(error), do: reason_of(error)
  defp saga_reason(_), do: nil

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  @doc """
  Friendly resource name from a stored module reference.

  Steps store `inspect(step.resource)` (`"Steward.Cookbook.Invoice"`) while
  plans store `to_string(module)` (`"Elixir.Steward.Cookbook.Invoice"`).
  Both reduce to the last segment, which is what §4 principle 5 asks be
  shown first.
  """
  def short_resource(nil), do: nil

  def short_resource(value) do
    value
    |> to_string()
    |> String.split(".")
    |> List.last()
  end

  # jsonb round-trips atom keys to strings, so read both.
  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp field(_, _), do: nil

  # ------------------------------------------------------------------
  # Filters applied after load (they need the decorated fields)
  # ------------------------------------------------------------------

  defp post_filter(rows, opts) do
    rows
    |> filter_by(opts[:resource], fn row, value ->
      Enum.any?(row.resources, &(&1 == value))
    end)
    |> filter_by(opts[:resource_id], fn row, value ->
      Enum.any?(row.steps_ordered, &(&1.resource_id == value))
    end)
    |> filter_by(opts[:has_errors], fn row, flag ->
      not flag or row.step_counts.failed > 0
    end)
    |> filter_by(presence(opts[:query]), fn row, term ->
      matches_query?(row, String.downcase(term))
    end)
  end

  defp filter_by(rows, nil, _fun), do: rows
  defp filter_by(rows, value, fun), do: Enum.filter(rows, &fun.(&1, value))

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: String.trim(value) |> presence_trimmed()

  defp presence_trimmed(""), do: nil
  defp presence_trimmed(value), do: value

  defp matches_query?(row, term) do
    haystack =
      [to_string(row.id), row.tool | Enum.map(row.steps_ordered, & &1.resource_id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase(to_string(&1)))

    Enum.any?(haystack, &String.contains?(&1, term))
  end

  defp sort_rows(rows, :duration),
    do: Enum.sort_by(rows, &(&1.duration_ms || 0), :desc)

  defp sort_rows(rows, _started), do: rows
end
