defmodule Steward.Sagas.StepRunner do
  @moduledoc """
  The `Reactor.Step` every plan step compiles to (docs/tech_spec.md §3.3
  "Steps declare run, compensate ..., and undo ..."; §8 Phase 4).

  One instance is added to the dynamically-built Reactor per plan step
  (`Steward.SagaExecutor`); `options` (the 3rd arg to `run/3`, 4th to
  `compensate/4`/`undo/4`) carries that step's `:plan_step` map, the
  owning `:saga_id`, and the plan-scoped `:borrow_tokens` map every step
  shares (CLAUDE.md: "Borrows may be plan-scoped... releasing early would
  expose intermediate state to other agents" — `Steward.SagaExecutor`
  acquires these once, before any step runs, and releases them once,
  after the whole saga finishes).

  Every action call carries that resource's plan-scoped `borrow_token`
  witness, plus a fresh, step-scoped `Steward.LeaseProvider` lease for
  mutating actions — fencing is per-write (spec §3.2), unlike borrowing.
  Both are keyed `{resource, resource_id}`, so a lease and a borrow always
  describe the same thing and resources sharing an id never collide.

  ## Capability disposition (CLAUDE.md invariant 3)

  `compensate/4` is where a failed step's capability disposition is
  decided, as "a function of the structured error taxonomy" (spec §4.3):

    * `{:stale_resource, remote_state}` — the capability *survives*:
      resync (re-fetch the current record) and return `:retry`, bounded
      by this step's `max_retries/1` option.
    * anything else, including `:invalid_transition` — *drop* it: give
      up (`{:error, reason}`), forcing the caller to submit a fresh plan
      with a new borrow and a fresh observation. `:invalid_transition`
      specifically shouldn't arise here in practice — `Steward.PlanValidator`
      already rejected any plan whose *declared* transitions don't line
      up, before a single borrow was acquired — so reaching this step
      with that reason means the resource drifted between validation and
      execution; there is no local repair for that, so it's dropped like
      any other unexpected error.

  `undo/4` runs a *different* action — whichever the failed capability
  declared as its `:undo` (if `reversibility: :undoable`) or
  `:compensate` (if `:compensatable`) action — reversing a step that had
  already succeeded, because a *later* step failed unrecoverably.
  `Steward.PlanValidator`'s reversibility ordering rule (CLAUDE.md
  invariant 6) guarantees an `:irreversible` step is never followed by
  anything that could trigger this, so `:irreversible` capabilities need
  no undo path here.

  A known v1 limitation: undo/compensate actions are called with no
  arguments beyond what the plan step declares via `:undo_args` /
  `:compensate_args` (default `%{}`) — they're expected to be
  self-contained (e.g. a `:refund` action reading `amount_paid` off the
  record itself), not parameterized from the original step's result.
  Cross-tier lease contention (`{:error, :lease_held}`, from
  `Steward.LeaseProvider`) is treated like any other non-retryable
  failure — v1 doesn't model contention from callers outside this saga.
  """

  use Reactor.Step

  alias Ash.Resource.Info, as: AshInfo
  alias Steward.{LeaseProvider, Sagas}
  alias Steward.Resource.Info, as: StewardInfo
  alias Steward.Sagas.ActionDispatcher

  @default_max_retries 3

  @doc "The `max_retries` Reactor step option a plan step should be added with."
  @spec max_retries(map()) :: non_neg_integer()
  def max_retries(step), do: Map.get(step, :max_retries, @default_max_retries)

  @impl true
  def run(_arguments, _reactor_context, opts) do
    step = opts[:plan_step]
    {:ok, saga_step} = upsert_saga_step(opts[:saga_id], step)

    case dispatch(step, opts) do
      {:ok, result} ->
        disposition = if linear?(step), do: :consumed, else: nil
        Sagas.succeed_saga_step(saga_step, safe_map(result), disposition)
        {:ok, result}

      {:error, :lease_held} ->
        {:error, :lease_held}

      {:error, ash_error} ->
        {:error, normalize(ash_error)}
    end
  end

  @impl true
  def compensate(reason, _arguments, _reactor_context, opts) do
    step = opts[:plan_step]

    case reason do
      {:stale_resource, _remote_state} ->
        resync(step)
        persist_failure(opts[:saga_id], step, reason, :survived)
        :retry

      other ->
        persist_failure(opts[:saga_id], step, other, :dropped)
        {:error, other}
    end
  end

  @impl true
  def undo(_value, _arguments, _reactor_context, opts) do
    step = opts[:plan_step]

    case undo_action(step) do
      nil ->
        :ok

      {action, args} ->
        undo_step = Map.merge(step, %{action: action, args: args})

        case dispatch(undo_step, opts) do
          {:ok, _result} ->
            {:ok, saga_step} = upsert_saga_step(opts[:saga_id], step)
            Sagas.undo_saga_step(saga_step)
            :ok

          {:error, :lease_held} ->
            {:error, :lease_held}

          {:error, ash_error} ->
            {:error, normalize(ash_error)}
        end
    end
  end

  defp dispatch(step, opts) do
    with_lease(step, opts, fn context ->
      ActionDispatcher.call(step.resource, step.resource_id, step.action, args(step), context)
    end)
  end

  defp undo_action(step) do
    case capability(step) do
      %{reversibility: :undoable, undo: undo} when not is_nil(undo) ->
        {undo, Map.get(step, :undo_args, %{})}

      %{reversibility: :compensatable, compensate: compensate} when not is_nil(compensate) ->
        {compensate, Map.get(step, :compensate_args, %{})}

      _no_reversal_declared ->
        nil
    end
  end

  defp with_lease(step, opts, fun) do
    context = build_context(step, opts)

    if mutating?(step) do
      # Leases are keyed exactly like borrows — `{resource, resource_id}`,
      # not the bare id. Two resources sharing an id (sequential integers,
      # or the same uuid mirrored across shadows) would otherwise contend
      # for one lease server and see spurious `{:error, :lease_held}`.
      key = borrow_key(step)

      case LeaseProvider.acquire(key) do
        {:ok, lease} ->
          try do
            fun.(put_in(context, [:steward, :lease], lease))
          after
            LeaseProvider.release(key, lease.ref)
          end

        {:error, :lease_held} ->
          {:error, :lease_held}
      end
    else
      fun.(context)
    end
  end

  defp build_context(step, opts) do
    Steward.witness(Map.fetch!(opts[:borrow_tokens], borrow_key(step)))
  end

  defp borrow_key(step), do: {step.resource, step.resource_id}

  defp mutating?(step) do
    case AshInfo.action(step.resource, step.action) do
      %{type: type} -> type in [:create, :update, :destroy]
      nil -> false
    end
  end

  defp linear?(step) do
    match?(%{consumption: :linear}, capability(step))
  end

  defp capability(step), do: StewardInfo.capability(step.resource, step.action)

  defp resync(step) do
    # Best-effort re-fetch to warm the shadow state before retrying; the
    # retried run/3 re-fetches the record itself regardless, so a failure
    # here isn't fatal — it's only a freshness optimization (spec §4.2).
    _ = Ash.get(step.resource, step.resource_id)
    :ok
  end

  defp args(step), do: Map.get(step, :args, %{})

  defp normalize(ash_error), do: ash_error |> Steward.Errors.reason() |> unwrap_reason()

  defp unwrap_reason({:error, reason, detail}), do: {reason, detail}
  defp unwrap_reason({:error, reason}), do: reason

  defp upsert_saga_step(saga_id, step) do
    Sagas.create_saga_step(
      saga_id,
      to_string(step.id),
      inspect(step.resource),
      to_string(step.resource_id),
      to_string(step.action)
    )
  end

  defp persist_failure(saga_id, step, reason, disposition) do
    {:ok, saga_step} = upsert_saga_step(saga_id, step)
    Sagas.fail_saga_step(saga_step, safe_map(%{reason: inspect(reason)}), disposition)
  end

  defp safe_map(%_struct{} = value), do: value |> Map.from_struct() |> safe_map()

  defp safe_map(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), inspect(v)} end)

  defp safe_map(value), do: %{"value" => inspect(value)}
end
