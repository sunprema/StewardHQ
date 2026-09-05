defmodule Steward.CapabilityRegistryTest do
  @moduledoc """
  Phase 5 definition-of-done coverage for `Steward.CapabilityRegistry`
  (docs/tech_spec.md §3.1 `own`; CLAUDE.md invariant 3 "capabilities are
  linear"): issue, move, linear-vs-reusable consumption, and
  process-death auto-expiry.
  """

  use ExUnit.Case, async: true

  alias Steward.{Capability, CapabilityRegistry}

  defp resource_id, do: {:test_capability, make_ref()}

  describe "issue/4" do
    test "issues an active capability held by the calling process by default" do
      assert {:ok, %Capability{name: :pay, consumption: :linear} = capability} =
               CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :pay,
                 consumption: :linear
               )

      assert CapabilityRegistry.status(capability) == :active
    end
  end

  describe "linear consumption" do
    test "a :pay capability is consumed exactly once — reuse fails :capability_expired" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :pay,
          consumption: :linear
        )

      assert :ok = CapabilityRegistry.use_capability(capability)
      assert CapabilityRegistry.status(capability) == :consumed
      assert {:error, :capability_expired} = CapabilityRegistry.use_capability(capability)
    end
  end

  describe "reusable consumption" do
    test "a :reusable capability stays active across repeated use" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :read,
          consumption: :reusable
        )

      assert :ok = CapabilityRegistry.use_capability(capability)
      assert :ok = CapabilityRegistry.use_capability(capability)
      assert CapabilityRegistry.status(capability) == :active
    end
  end

  describe "move/2" do
    test "moving consumes the sender's ref and mints a new one for the receiver" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :pay,
          consumption: :linear
        )

      test_pid = self()

      {:ok, receiver_pid} =
        Task.start(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, moved} = CapabilityRegistry.move(capability, receiver_pid)
      assert moved.ref != capability.ref

      # Reusing the original (sender's) ref is exactly the confused-deputy
      # case §3.1 rules out.
      assert {:error, :capability_moved} = CapabilityRegistry.use_capability(capability)
      assert {:error, :capability_moved} = CapabilityRegistry.move(capability, self())

      # The new ref is fully usable.
      assert :ok = CapabilityRegistry.use_capability(moved)

      send(receiver_pid, :stop)
      _ = test_pid
    end

    test "moving an already-moved capability fails :capability_moved, never a silent no-op" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :pay,
          consumption: :linear
        )

      {:ok, pid_a} = Task.start(fn -> Process.sleep(:infinity) end)
      {:ok, pid_b} = Task.start(fn -> Process.sleep(:infinity) end)

      assert {:ok, _moved} = CapabilityRegistry.move(capability, pid_a)
      assert {:error, :capability_moved} = CapabilityRegistry.move(capability, pid_b)
    end
  end

  describe "process death" do
    test "the holder dying auto-expires the capability without any cooperative cleanup" do
      {:ok, holder_pid} = Task.start(fn -> Process.sleep(:infinity) end)

      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :read,
          holder: holder_pid
        )

      assert CapabilityRegistry.status(capability) == :active

      ref = Process.monitor(holder_pid)
      Process.exit(holder_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder_pid, :killed}

      # CapabilityRegistry's own monitor is async relative to ours; poll briefly.
      assert wait_until(fn -> CapabilityRegistry.status(capability) == :expired end)
      assert {:error, :capability_expired} = CapabilityRegistry.use_capability(capability)
    end
  end

  describe "expire/1" do
    test "force-expires a :reusable capability that use_capability alone would never invalidate" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :read,
          consumption: :reusable
        )

      assert :ok = CapabilityRegistry.expire(capability)
      assert CapabilityRegistry.status(capability) == :expired
      assert {:error, :capability_expired} = CapabilityRegistry.use_capability(capability)
    end

    test "is idempotent and safe on an already-moved ref" do
      {:ok, capability} =
        CapabilityRegistry.issue(Steward.Test.Examples.Invoice, resource_id(), :read,
          consumption: :reusable
        )

      {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)

      assert {:ok, _moved} = CapabilityRegistry.move(capability, pid)
      assert :ok = CapabilityRegistry.expire(capability)
      assert :ok = CapabilityRegistry.expire(capability)
    end
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
