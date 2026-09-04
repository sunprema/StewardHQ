defmodule Steward.RepairLoop do
  @moduledoc """
  Re-fetch-until-consistent primitive for post-write reconciliation
  failures (docs/tech_spec.md §4.2 "Repair loop": "if a backend call
  succeeds but reconciliation fails, the gateway itself is the drifted
  party while holding a lock. It must re-fetch until consistent before
  releasing the borrow, or it poisons the next borrower"; CLAUDE.md
  invariant 5).

  This is a standalone primitive, not wired into
  `Steward.ResourceServer.release/2` — the resource server is
  arbitration-only per CLAUDE.md ("keep them small... no business
  logic"), and the real wiring point for "release only after
  consistency" is the Phase 4 Reactor saga. Until then, callers compose
  it by hand: acquire a borrow, write, `run/4` before releasing.

  Also serves as the deep-sync fallback `Steward.Idempotency` documents
  for `idempotency :none` backends: when a write's outcome is ambiguous,
  poll the backend's read endpoint until it matches what was expected
  before deciding whether the saga failed or succeeded.
  """

  @default_max_attempts 5
  @default_backoff_ms 100

  @doc """
  Calls `backend.fetch(resource_id)` repeatedly until `expect.(state)` is
  true or `opts[:max_attempts]` (default #{@default_max_attempts}) is
  exhausted, sleeping `opts[:backoff_ms]` (default #{@default_backoff_ms}ms)
  between attempts.
  """
  @spec run(module(), term(), (map() -> boolean()), keyword()) ::
          {:ok, Steward.Backend.snapshot()} | {:error, :repair_failed, term()}
  def run(backend, resource_id, expect, opts \\ []) when is_function(expect, 1) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    backoff_ms = Keyword.get(opts, :backoff_ms, @default_backoff_ms)
    attempt(backend, resource_id, expect, max_attempts, backoff_ms, nil)
  end

  defp attempt(_backend, _resource_id, _expect, 0, _backoff_ms, last) do
    {:error, :repair_failed, last}
  end

  defp attempt(backend, resource_id, expect, attempts_left, backoff_ms, _last) do
    case backend.fetch(resource_id) do
      {:ok, snapshot} ->
        if expect.(snapshot.state) do
          {:ok, snapshot}
        else
          maybe_sleep(attempts_left, backoff_ms)
          attempt(backend, resource_id, expect, attempts_left - 1, backoff_ms, snapshot.state)
        end

      {:error, reason} ->
        maybe_sleep(attempts_left, backoff_ms)
        attempt(backend, resource_id, expect, attempts_left - 1, backoff_ms, {:error, reason})
    end
  end

  defp maybe_sleep(attempts_left, backoff_ms) when attempts_left > 1,
    do: Process.sleep(backoff_ms)

  defp maybe_sleep(_attempts_left, _backoff_ms), do: :ok
end
