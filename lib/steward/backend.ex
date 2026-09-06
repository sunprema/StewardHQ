defmodule Steward.Backend do
  @moduledoc """
  Behaviour for the legacy API boundary that fenced writes are made
  against (docs/tech_spec.md §4.2 implementation note, §9 "API adapters"
  seam).

  Per CLAUDE.md's testing convention ("mock only the legacy-API
  boundary... this is the one seam v1 does abstract"), this is the single
  pluggable seam Phase 2 introduces — not a general invitation to add
  more provider behaviours ahead of schedule (spec §9's other seams,
  including `Steward.LeaseProvider`, are deliberately hardcoded modules
  in v1, not behaviours).

  A real implementation would call out to the actual legacy system
  (Stripe, SAP, a homegrown REST API, ...); `Steward.Changes.EnforceFencing`
  is the only caller and does not care which.
  """

  @typedoc "Opaque backend-side identifier for the resource being fenced."
  @type resource_id :: term()

  @typedoc "A snapshot of backend state plus the version token (ETag) it was read at."
  @type snapshot :: %{version: term(), state: map()}

  @doc "Reads the current version and state of `resource_id` from the backend."
  @callback fetch(resource_id()) :: {:ok, snapshot()} | {:error, term()}

  @doc """
  Performs a fenced, idempotent write: `changes` merged into
  `resource_id`'s backend state, conditional on `expected_version` still
  being current, carrying `fencing_token` (spec §3.2 — "every lease
  carries a monotonically increasing token that must accompany the
  backend write").

  Returns `{:error, :stale_resource, remote_state}` when
  `expected_version` no longer matches — the backend's own state at the
  time of rejection, per the spec §4.4 taxonomy.

  ## `opts[:idempotency_key]`

  The key is a required *parameter* even though honouring it is
  optional, because a backend that never sees the key cannot be
  idempotent, and spec §4.2 calls idempotency keys "the primary
  defense" against the phantom payment: a write the backend performed
  but whose response was lost. Retrying that write without a key charges
  twice; retrying with one is safe by construction.

  Each backend applies the key however its transport declares in the
  DSL's `idempotency :header | :body_field | :none` (spec §6) — an HTTP
  backend sets a header, an in-memory one records the key and replays
  the stored result. `:none` backends ignore it, which is exactly the
  case spec §4.2 covers with the deep-sync repair fallback
  (`Steward.RepairLoop`) instead.

  The key is stable across every retry of the same logical write —
  including a retry after a crash and `Steward.SagaExecutor.resume/1` —
  and differs between any two distinct writes. See
  `Steward.Idempotency.step_key/2`. It is `nil` only for callers outside
  a saga, which have no step identity to derive one from.

  Never derive the key from the fencing token. They move in opposite
  directions: a fencing token must change on every new lease, an
  idempotency key must stay the same across the retries of one attempt.
  Using one as the other defeats both.
  """
  @callback write(
              resource_id(),
              changes :: map(),
              fencing_token :: term(),
              expected_version :: term(),
              opts :: keyword()
            ) ::
              {:ok, snapshot()} | {:error, :stale_resource, map()} | {:error, term()}
end
