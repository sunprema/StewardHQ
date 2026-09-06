defmodule Steward.Test.Borrows do
  @moduledoc """
  Acquires *real* borrows for tests that need to call a stewarded Ash
  action (CLAUDE.md: "No mocks for the borrow checker. Use real
  GenServers in tests").

  Before `Steward.ResourceServer.verify_borrow/3` existed, test setup
  could satisfy the Witness Pattern with
  `context: %{steward: %{borrow_token: make_ref()}}` — a token no
  resource server ever issued. That made the setup convenient and the
  suite dishonest: it proved an action rejects a *missing* witness, never
  that it rejects a forged one. These helpers acquire the borrow for
  real, so setup exercises the same path production does.
  """

  alias Steward.ResourceServer

  @doc """
  Runs `fun` while holding a real `mode` borrow on `{resource,
  resource_id}`, passing it the action context that witnesses it. The
  borrow is released when `fun` returns, so a later saga can acquire the
  same resource without contending with the setup that built it.
  """
  @spec witnessed(module(), term(), :shared | :exclusive, (map() -> result)) :: result
        when result: var
  def witnessed(resource, resource_id, mode \\ :exclusive, fun) when is_function(fun, 1) do
    ResourceServer.borrow({resource, resource_id}, mode, fn token ->
      fun.(Steward.witness(token))
    end)
  end

  @doc """
  Like `witnessed/4`, for a `:create`: there is no record id to borrow
  against yet, so the borrow is taken on a unique placeholder id.

  This is not a loophole — `verify_borrow/3` still checks the borrow is
  live, held by this process, and taken on this resource module. It is
  the honest shape of the problem: a create cannot be scoped to a record
  that does not exist, which is also why `Steward.MCP.Tool` refuses to
  expose `:create` actions at all.
  """
  @spec creating(module(), (map() -> result)) :: result when result: var
  def creating(resource, fun) when is_function(fun, 1) do
    witnessed(resource, {:create, System.unique_integer([:positive])}, :exclusive, fun)
  end
end
