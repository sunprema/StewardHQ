defmodule Steward.LeaseFencingIntegrationTest do
  @moduledoc """
  End-to-end composition proving invariant 5's intended pattern
  ("locks release only after consistency"): local exclusive borrow, a
  backend lease with a fencing token, a fenced write, a repair-loop
  reconciliation, then release — using real `Steward.ResourceServer` and
  `Steward.LeaseProvider` GenServers and the real `Steward.Shadows.Invoice`
  resource. The only mock is the legacy-API boundary
  (`Steward.Test.FakeBackend`), per CLAUDE.md's testing convention.

  This wiring is deliberately manual: `Steward.RepairLoop` is not
  hard-wired into `Steward.ResourceServer.release/2` (see both modules'
  moduledocs) — the real wiring point is the Phase 4 Reactor saga.
  """

  use Steward.DataCase, async: true

  alias Steward.{LeaseProvider, RepairLoop, ResourceServer, Shadows}
  alias Steward.Test.FakeBackend

  test "borrow -> lease -> fenced write -> repair -> release composes correctly" do
    external_id = "invoice-#{System.unique_integer([:positive])}"
    FakeBackend.seed(external_id, 0, %{amount_paid: Decimal.new(0)})

    invoice =
      Shadows.create_invoice!(%{
        external_id: external_id,
        status: :approved,
        total_amount: Decimal.new(100)
      })

    result =
      ResourceServer.borrow(external_id, :exclusive, fn ->
        assert {:ok, lease} = LeaseProvider.acquire(external_id)

        assert {:ok, updated} =
                 Shadows.record_payment(invoice, Decimal.new(25),
                   context: %{steward: %{lease: lease}}
                 )

        assert {:ok, _snapshot} =
                 RepairLoop.run(FakeBackend, external_id, &(&1.amount_paid == Decimal.new(25)))

        assert :ok = LeaseProvider.release(external_id, lease.ref)
        updated
      end)

    assert Decimal.equal?(result.amount_paid, Decimal.new(25))
    assert %{exclusive: nil} = ResourceServer.borrows(external_id)
    assert LeaseProvider.current(external_id) == nil
  end
end
