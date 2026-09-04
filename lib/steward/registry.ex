defmodule Steward.Registry do
  @moduledoc """
  Process directory mapping a `resource_id` to its `Steward.ResourceServer`.

  Implements the addressing half of spec §8 Phase 1 ("`Steward.Registry`
  tracking active borrows..."): the borrow state itself is owned by each
  resource's `Steward.ResourceServer` (kept small per CLAUDE.md's GenServer
  convention — arbitration only, no shared mutable ledger). This module is
  the directory used to name and find that process, wrapping Elixir's
  native `Registry` per CLAUDE.md's "registered via Registry" convention.

  Capability token tracking and move semantics (spec §3.1 `own`) belong to
  Phase 5 (spec §8) and are intentionally not implemented here yet — see
  CLAUDE.md: "don't build ahead of the current phase."
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc "Via-tuple used to name a resource's `Steward.ResourceServer` process."
  @spec via_tuple(term()) :: {:via, Registry, {__MODULE__, term()}}
  def via_tuple(resource_id), do: {:via, Registry, {__MODULE__, resource_id}}

  @doc "Looks up the running `Steward.ResourceServer` pid for `resource_id`, if any."
  @spec whereis(term()) :: {:ok, pid()} | :error
  def whereis(resource_id) do
    case Registry.lookup(__MODULE__, resource_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
