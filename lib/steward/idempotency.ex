defmodule Steward.Idempotency do
  @moduledoc """
  Idempotency-key generation and injection for mutating backend calls
  (docs/tech_spec.md §4.2 "Idempotency keys — the phantom-payment
  defense", §6 `idempotency :header | :body_field | :none`, §8 Phase 2).

  `Steward.Sagas.StepRunner` calls `step_key/2` for every saga step and
  puts the result in the action context, from where
  `Steward.Changes.EnforceFencing` hands it to `c:Steward.Backend.write/5`.
  `generate_key/0` remains for callers outside a saga, which have
  somewhere of their own to store the key between attempts.

  For backends declaring `idempotency :none`, spec §4.2's fallback is a
  deep-sync repair step: after a write whose outcome is ambiguous (e.g. a
  timeout), call `Steward.RepairLoop.run/4` against the backend's read
  endpoint to determine what actually happened before deciding whether
  the saga failed or succeeded. `inject/4` does not do this
  automatically for `:none` — there is no saga step to attach it to yet.
  """

  @type mode :: :header | :body_field | :none

  @doc """
  Generates a fresh idempotency key. The caller is responsible for
  storing it and reusing it across retries of the same write attempt —
  a freshly generated key on a retry is not a retry, it is a second
  write.

  Prefer `step_key/2` inside a saga: a random key cannot survive a crash
  and `Steward.SagaExecutor.resume/1`, which is precisely when the
  phantom-payment defense has to hold.
  """
  @spec generate_key() :: String.t()
  def generate_key, do: Ash.UUID.generate()

  @doc """
  The idempotency key for one plan step of one saga — derived, not
  random, and therefore stable in the two directions that matter
  (docs/tech_spec.md §4.2):

    * **the same** for every retry of that step, including
      Reactor's in-process `:retry` after a `:stale_resource`
      compensation, and a retry that arrives via
      `Steward.SagaExecutor.resume/1` in a *different process*, minutes
      later, after the original run's process died. Both saga id and
      step id are persisted (`Steward.Sagas.Saga`'s `:plan`), so the
      key derived on resume is bit-for-bit the one the first attempt
      sent. A random key would not be, and the retry that follows an
      ambiguous timeout — the exact case this defends — would charge a
      second time.

    * **different** for any two distinct steps, since the saga id is a
      UUID and step ids are unique within a plan. Two steps sharing a
      key would make the second a silent no-op replay of the first.

  Readable on purpose: this string shows up in backend logs and in
  Stripe's dashboard, where `"<saga>:<step>"` is traceable back to the
  plan that sent it and an opaque hash is not.
  """
  @spec step_key(term(), term()) :: String.t()
  def step_key(saga_id, step_id), do: "#{saga_id}:#{scalar(step_id)}"

  defp scalar(id) when is_binary(id), do: id
  defp scalar(id) when is_integer(id) or is_atom(id), do: to_string(id)

  # A step id that isn't a JSON-safe scalar can't survive
  # `Steward.Sagas.PlanCodec` anyway, so such a plan is never resumed and
  # only in-process retries have to agree — which `inspect/1` gives.
  defp scalar(id), do: inspect(id)

  @doc """
  Injects `key` into `request` per `mode`:

    * `:header` — sets `request[:headers][name]` (default header name
      `"Idempotency-Key"`).
    * `:body_field` — sets `request[:body][name]` (default field name
      `"idempotency_key"`).
    * `:none` — no-op; the backend doesn't support idempotency keys. See
      the moduledoc for the deep-sync repair fallback.

  `request` is a plain map with optional `:headers` / `:body` sub-maps;
  merge semantics only, no HTTP client coupling.
  """
  @spec inject(map(), String.t(), mode(), keyword()) :: map()
  def inject(request, key, mode, opts \\ [])

  def inject(request, key, :header, opts) do
    name = Keyword.get(opts, :name, "Idempotency-Key")
    Map.update(request, :headers, %{name => key}, &Map.put(&1, name, key))
  end

  def inject(request, key, :body_field, opts) do
    name = Keyword.get(opts, :name, "idempotency_key")
    Map.update(request, :body, %{name => key}, &Map.put(&1, name, key))
  end

  def inject(request, _key, :none, _opts), do: request
end
