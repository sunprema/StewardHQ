defmodule Steward.Idempotency do
  @moduledoc """
  Idempotency-key generation and injection for mutating backend calls
  (docs/tech_spec.md §4.2 "Idempotency keys — the phantom-payment
  defense", §6 `idempotency :header | :body_field | :none`, §8 Phase 2).

  There is no Reactor saga or DSL yet (Phases 3-4) to generate and attach
  one key per plan step automatically, so this module is the mechanism a
  caller uses by hand today: generate a key once per logical write
  attempt (including retries of that same attempt), and inject it into
  the outgoing request the same way every time so retries are safe by
  construction.

  For backends declaring `idempotency :none`, spec §4.2's fallback is a
  deep-sync repair step: after a write whose outcome is ambiguous (e.g. a
  timeout), call `Steward.RepairLoop.run/4` against the backend's read
  endpoint to determine what actually happened before deciding whether
  the saga failed or succeeded. `inject/4` does not do this
  automatically for `:none` — there is no saga step to attach it to yet.
  """

  @type mode :: :header | :body_field | :none

  @doc "Generates a fresh idempotency key. Callers reuse it across retries of the same write attempt."
  @spec generate_key() :: String.t()
  def generate_key, do: Ash.UUID.generate()

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
