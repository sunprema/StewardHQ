defmodule Steward.SpawnAgentTest do
  @moduledoc """
  Phase 5 definition-of-done coverage for `Steward.SpawnAgent`
  (docs/tech_spec.md §3.4, §8 Phase 5): moving a capability into a
  supervised sub-agent task, and CLAUDE.md invariant 4 ("no capability
  outlives its plan... process death must release borrows automatically")
  applied to that child.
  """

  use ExUnit.Case, async: true

  alias Steward.{CapabilityRegistry, SpawnAgent}
  alias Steward.Test.Examples.Invoice

  test "moves the capability into the child, which the parent can no longer use" do
    test_pid = self()

    {:ok, capability} =
      CapabilityRegistry.issue(Invoice, {:test, make_ref()}, :pay, consumption: :linear)

    assert {:ok, _child_pid} =
             SpawnAgent.spawn_agent(:process_payment,
               moves: [capability],
               task: fn [moved] ->
                 send(test_pid, {:child_saw, moved.ref, CapabilityRegistry.use_capability(moved)})
               end
             )

    assert_receive {:child_saw, child_ref, :ok}, 1_000
    assert child_ref != capability.ref

    # The parent's original ref is consumed by the move — the confused-
    # deputy problem §3.1 exists to rule out.
    assert {:error, :capability_moved} = CapabilityRegistry.use_capability(capability)
  end

  test "a crashing child auto-releases its moved capability without cooperative cleanup" do
    test_pid = self()

    {:ok, capability} =
      CapabilityRegistry.issue(Invoice, {:test, make_ref()}, :read, consumption: :reusable)

    assert {:ok, child_pid} =
             SpawnAgent.spawn_agent(:flaky_agent,
               moves: [capability],
               task: fn [moved] ->
                 send(test_pid, {:moved_capability, moved})
                 raise "boom"
               end
             )

    # `capability` itself is already permanently :moved the instant the
    # move into the child happens — the invariant under test is about
    # *that* fresh ref (held by the child), not the sender's stale one.
    assert_receive {:moved_capability, moved}, 1_000

    ref = Process.monitor(child_pid)
    assert_receive {:DOWN, ^ref, :process, ^child_pid, _reason}, 1_000

    assert wait_until(fn -> CapabilityRegistry.status(moved) == :expired end)
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
