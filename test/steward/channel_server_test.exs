defmodule Steward.ChannelServerTest do
  @moduledoc """
  Phase 5 definition-of-done coverage for `Steward.ChannelServer`
  (docs/tech_spec.md §3.4, §8 Phase 5): bounded capacity under both
  overflow policies, `require_intent`, `allow_delegation`, capability
  delegation as a genuine two-hop linear move, and channel-close teardown
  of undelivered capabilities.
  """

  use ExUnit.Case, async: true

  alias Steward.{CapabilityRegistry, ChannelServer}
  alias Steward.Test.Examples.{BillingProtocol, Invoice}

  defp instance_id, do: make_ref()

  describe "overflow :reject" do
    test "a send past capacity fails :channel_full immediately, capacity 1 is not empty-queue capacity" do
      id = instance_id()

      assert :ok =
               ChannelServer.send_message(BillingProtocol, :reject_on_full, id, :ping, %{n: 1})

      assert {:error, :channel_full} =
               ChannelServer.send_message(BillingProtocol, :reject_on_full, id, :ping, %{n: 2})

      assert {:ok, %{message: :ping, payload: %{n: 1}}} =
               ChannelServer.receive_message(BillingProtocol, :reject_on_full, id)
    end
  end

  describe "overflow :block" do
    test "a send past capacity blocks up to overflow_timeout, then fails :channel_full" do
      id = instance_id()

      assert :ok = ChannelServer.send_message(BillingProtocol, :block_on_full, id, :ping, %{n: 1})

      assert {:error, :channel_full} =
               ChannelServer.send_message(BillingProtocol, :block_on_full, id, :ping, %{n: 2})
    end

    test "a blocked send is granted as soon as the receiver drains the queue" do
      id = instance_id()
      test_pid = self()

      assert :ok = ChannelServer.send_message(BillingProtocol, :block_on_full, id, :ping, %{n: 1})

      spawn(fn ->
        result =
          ChannelServer.send_message(BillingProtocol, :block_on_full, id, :ping, %{n: 2},
            timeout: 5_000
          )

        send(test_pid, {:send_result, result})
      end)

      Process.sleep(50)
      refute_received {:send_result, _}

      assert {:ok, %{payload: %{n: 1}}} =
               ChannelServer.receive_message(BillingProtocol, :block_on_full, id)

      assert_receive {:send_result, :ok}, 1_000
    end
  end

  describe "require_intent" do
    test "a send with no :intent fails :intent_required" do
      id = instance_id()

      assert {:error, :intent_required} =
               ChannelServer.send_message(BillingProtocol, :requires_intent, id, :ping, %{})
    end

    test "a send carrying :intent succeeds" do
      id = instance_id()

      assert :ok =
               ChannelServer.send_message(BillingProtocol, :requires_intent, id, :ping, %{},
                 intent: :greet
               )

      assert {:ok, %{message: :ping}} =
               ChannelServer.receive_message(BillingProtocol, :requires_intent, id)
    end
  end

  describe "allow_delegation" do
    test "a capability outside the declared list fails :capability_not_delegable" do
      id = instance_id()

      {:ok, capability} =
        CapabilityRegistry.issue(Invoice, {:test, make_ref()}, :write, consumption: :linear)

      assert {:error, :capability_not_delegable} =
               ChannelServer.send_message(
                 BillingProtocol,
                 :delegates_read_only,
                 id,
                 :handoff,
                 %{},
                 capability: capability
               )

      # A never-accepted capability is untouched — still usable directly.
      assert CapabilityRegistry.status(capability) == :active
    end

    test "an allowed capability rides the message and arrives as a genuine second move" do
      id = instance_id()

      {:ok, capability} =
        CapabilityRegistry.issue(Invoice, {:test, make_ref()}, :read, consumption: :linear)

      original_ref = capability.ref

      assert :ok =
               ChannelServer.send_message(
                 BillingProtocol,
                 :delegates_read_only,
                 id,
                 :handoff,
                 %{},
                 capability: capability
               )

      # Sender's original ref is already consumed — the first (sender →
      # channel) hop of the move.
      assert {:error, :capability_moved} = CapabilityRegistry.use_capability(capability)

      assert {:ok, %{payload: %{capability: received}}} =
               ChannelServer.receive_message(BillingProtocol, :delegates_read_only, id)

      # The delivered capability is a fresh ref (channel → receiver, the
      # second hop) and is fully usable by its new holder.
      assert received.ref != original_ref
      assert :ok = CapabilityRegistry.use_capability(received)
    end
  end

  describe "close/3" do
    test "closing expires every capability still sitting undelivered in the queue" do
      id = instance_id()

      {:ok, capability} =
        CapabilityRegistry.issue(Invoice, {:test, make_ref()}, :read, consumption: :reusable)

      assert :ok =
               ChannelServer.send_message(
                 BillingProtocol,
                 :delegates_read_only,
                 id,
                 :handoff,
                 %{},
                 capability: capability
               )

      # The capability that actually sits in the queue is the *moved*
      # one (sender → channel, the first hop) — a fresh ref, distinct
      # from `capability` above, which is already permanently :moved.
      assert %{queued_capabilities: [queued]} =
               ChannelServer.inspect_state(BillingProtocol, :delegates_read_only, id)

      assert :ok = ChannelServer.close(BillingProtocol, :delegates_read_only, id)

      # :reusable capabilities would otherwise never invalidate via
      # ordinary use — closing must force it, not merely "use" it.
      assert CapabilityRegistry.status(queued) == :expired
    end

    test "sends and receives against a closed channel fail :channel_closed" do
      id = instance_id()

      assert :ok =
               ChannelServer.send_message(BillingProtocol, :requires_intent, id, :ping, %{},
                 intent: :x
               )

      assert :ok = ChannelServer.close(BillingProtocol, :requires_intent, id)

      assert {:error, :channel_closed} =
               ChannelServer.send_message(BillingProtocol, :requires_intent, id, :ping, %{},
                 intent: :x
               )

      assert {:error, :channel_closed} =
               ChannelServer.receive_message(BillingProtocol, :requires_intent, id)
    end
  end
end
