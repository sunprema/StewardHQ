defmodule Steward.PlanValidator do
  @moduledoc """
  Static analysis of a plan graph against the resources' compiled
  Resource Safety Graphs, before any borrow is acquired or any backend
  call is made (docs/tech_spec.md §5 "Plan Validator + DSL Laws (Spark) →
  Legibility", §7 "Static analysis. The Plan Validator simulates the plan
  against the Safety Graph", §8 Phase 3).

  A plan is a flat, ordered list of steps (spec §3.3's plan graph,
  simplified to its execution order for v1 — see `t:step/0`); Phase 4's
  Reactor integration is what will turn a real dependency graph into this
  ordering. `validate/2` runs, in order:

    1. **State-machine simulation** — each step naming a declared
       `transition` must find the resource in that transition's `:from`
       state (starting from `Steward.Resource.Info.initial_state/1`, or
       `opts[:initial_states]` overrides); mismatches fail closed with
       `{:error, :invalid_transition, current_state}` (CLAUDE.md
       conventions: "transitions only through the DSL-declared graph").
    2. **Freshness checks** — a step against a capability declaring
       `requires_freshness: {:max_age, ms}` must carry `:observed_at`
       within that bound, or fails as `{:error, :stale_resource, info}`
       (spec §4.2).
    3. **Reversibility ordering** — CLAUDE.md invariant 6: no step may
       follow an `:irreversible` step. Violations fail as
       `{:error, :irreversible_before_fallible, step_id}`.

  `canonical_borrow_order/1` is the fourth piece (spec §4.1 "Deadlock
  policy": "the Plan Validator sorts all requested borrows canonically
  (resource_type:id) and acquisition follows that global order,
  preventing circular waits") — kept as a separate function rather than a
  `validate/2` failure mode, since it produces an acquisition order for
  the caller to follow rather than rejecting the plan.
  """

  alias Steward.Resource.Info, as: ResourceInfo

  @typedoc """
  One step of a plan. `:resource` must use the `Steward.Resource`
  extension. `:action` is the capability/action name being exercised.
  `:observed_at` is when the agent last observed this resource's shadow
  state — required only when the matching capability declares a
  `requires_freshness` bound.
  """
  @type step :: %{
          required(:id) => term(),
          required(:resource) => module(),
          required(:resource_id) => term(),
          required(:action) => atom(),
          optional(:observed_at) => DateTime.t()
        }

  @type error ::
          {:error, :invalid_transition, atom() | nil}
          | {:error, :stale_resource, map()}
          | {:error, :irreversible_before_fallible, term()}

  @doc """
  Validates `steps` in order. `opts`:

    * `:now` — the reference time for freshness checks (default `DateTime.utc_now/0`).
    * `:initial_states` — `%{{resource, resource_id} => state}` overrides
      for resources not starting from their DSL-declared initial state.
  """
  @spec validate([step()], keyword()) :: :ok | error()
  def validate(steps, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    initial_states = Keyword.get(opts, :initial_states, %{})

    with :ok <- simulate_state_machine(steps, initial_states),
         :ok <- check_freshness(steps, now) do
      check_reversibility_order(steps)
    end
  end

  @doc """
  Sorts every resource touched by `steps` into canonical
  `"ResourceModule:resource_id"` order, paired with the strongest borrow
  mode any step requires of it (`:exclusive` if any step does, else
  `:shared`). Acquiring borrows in this order, for multi-resource plans,
  prevents circular waits (spec §4.1).
  """
  @spec canonical_borrow_order([step()]) :: [{String.t(), :shared | :exclusive}]
  def canonical_borrow_order(steps) do
    steps
    |> Enum.group_by(&borrow_key/1)
    |> Enum.map(fn {key, group} ->
      mode =
        if Enum.any?(group, &(capability_mode(&1) == :exclusive)), do: :exclusive, else: :shared

      {key, mode}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp borrow_key(step), do: "#{inspect(step.resource)}:#{step.resource_id}"

  defp capability_mode(step) do
    case ResourceInfo.capability(step.resource, step.action) do
      %{mode: mode} -> mode
      nil -> :exclusive
    end
  end

  defp simulate_state_machine(steps, initial_states) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, states} ->
      case ResourceInfo.transition(step.resource, step.action) do
        nil -> {:cont, {:ok, states}}
        transition -> apply_transition(step, transition, states, initial_states)
      end
    end)
    |> case do
      {:ok, _states} -> :ok
      error -> error
    end
  end

  defp apply_transition(step, transition, states, initial_states) do
    key = {step.resource, step.resource_id}
    default = Map.get(initial_states, key, ResourceInfo.initial_state(step.resource))
    current = Map.get(states, key, default)

    if current == transition.from do
      {:cont, {:ok, Map.put(states, key, transition.to)}}
    else
      {:halt, {:error, :invalid_transition, current}}
    end
  end

  defp check_freshness(steps, now) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case ResourceInfo.capability(step.resource, step.action) do
        %{requires_freshness: {:max_age, max_age_ms}} ->
          check_step_freshness(step, max_age_ms, now)

        _no_freshness_requirement ->
          {:cont, :ok}
      end
    end)
  end

  defp check_step_freshness(step, max_age_ms, now) do
    case Map.get(step, :observed_at) do
      nil ->
        {:halt, {:error, :stale_resource, %{step: step.id, reason: :not_observed}}}

      observed_at ->
        age_ms = DateTime.diff(now, observed_at, :millisecond)

        if age_ms <= max_age_ms do
          {:cont, :ok}
        else
          {:halt,
           {:error, :stale_resource, %{step: step.id, age_ms: age_ms, max_age_ms: max_age_ms}}}
        end
    end
  end

  defp check_reversibility_order(steps) do
    steps
    |> Enum.reduce_while(:none, fn step, seen ->
      case {seen, capability_reversibility(step)} do
        {{:irreversible, step_id}, reversibility} when reversibility != :irreversible ->
          {:halt, {:error, :irreversible_before_fallible, step_id}}

        {:none, :irreversible} ->
          {:cont, {:irreversible, step.id}}

        {seen, _reversibility} ->
          {:cont, seen}
      end
    end)
    |> case do
      {:error, _reason, _detail} = error -> error
      _no_violation -> :ok
    end
  end

  defp capability_reversibility(step) do
    case ResourceInfo.capability(step.resource, step.action) do
      %{reversibility: reversibility} -> reversibility
      nil -> :undoable
    end
  end
end
