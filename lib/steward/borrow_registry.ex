defmodule Steward.BorrowRegistry do
  @moduledoc """
  Global index of *live* borrows: `borrow_ref => %{key, mode, holder}`
  (docs/tech_spec.md §4.1 "The Witness Pattern — making the borrow
  checker unbypassable"; CLAUDE.md invariant 1).

  `Steward.Registry` addresses resource *servers*; this addresses the
  individual borrows those servers have granted, so a witness check can
  answer "is this token a live borrow, and is the process presenting it
  the one it was granted to?" in O(1) without knowing which
  `Steward.ResourceServer` to ask.

  Entries are registered *by the granting `Steward.ResourceServer`
  process*, not by the holder, so:

    * release and `Process.monitor`-driven auto-release both unregister
      explicitly (`Steward.ResourceServer`), and
    * if a resource server itself dies, every borrow it had granted
      disappears with it — which is correct: those borrows are gone.

  This exists because presence of a token in changeset context proves
  nothing. Before this module, `Steward.Resource.Validations.RequireWitness`
  accepted any non-nil term, so `context: %{steward: %{borrow_token:
  make_ref()}}` satisfied the "unbypassable" borrow checker. The witness
  is now checked against the authority that issued it.
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @typedoc "What a live borrow record carries: the key it was granted on, its mode, and the process holding it."
  @type entry :: %{key: term(), mode: :shared | :exclusive, holder: pid()}

  @doc """
  Records a granted borrow. Must be called from the granting
  `Steward.ResourceServer` process.
  """
  @spec register(reference(), entry()) :: :ok
  def register(borrow_ref, %{key: _key, mode: _mode, holder: _holder} = entry) do
    {:ok, _owner} = Registry.register(__MODULE__, borrow_ref, entry)
    :ok
  end

  @doc """
  Removes a released borrow. Must be called from the granting
  `Steward.ResourceServer` process. Idempotent.
  """
  @spec unregister(reference()) :: :ok
  def unregister(borrow_ref), do: Registry.unregister(__MODULE__, borrow_ref)

  @doc "Looks up a live borrow by its token, or `:error` if it was never granted or is already released."
  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(borrow_ref) when is_reference(borrow_ref) do
    case Registry.lookup(__MODULE__, borrow_ref) do
      [{_resource_server, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  # A non-reference can never have been issued by Steward.ResourceServer.
  def fetch(_not_a_borrow_ref), do: :error
end
