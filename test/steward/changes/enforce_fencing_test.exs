defmodule Steward.Changes.EnforceFencingTest do
  @moduledoc """
  Phase 2 definition-of-done coverage for `Steward.Changes.EnforceFencing`
  against the real `Steward.Shadows.Invoice` resource: missing lease,
  expired lease, backend-side drift, and the happy path (docs/tech_spec.md
  §4.2, §4.4; CLAUDE.md invariant 2).
  """

  use Steward.DataCase, async: true

  alias Steward.LeaseProvider
  alias Steward.Shadows
  alias Steward.Test.FakeBackend

  defp external_id, do: "invoice-#{System.unique_integer([:positive])}"

  defp create_invoice!(external_id) do
    FakeBackend.seed(external_id, 0, %{amount_paid: Decimal.new(0)})

    Shadows.create_invoice!(%{
      external_id: external_id,
      status: :approved,
      total_amount: Decimal.new(100)
    })
  end

  test "a write without a lease in context is rejected as :unfenced_write" do
    invoice = create_invoice!(external_id())

    assert {:error, ash_error} = Shadows.record_payment(invoice, Decimal.new(10))
    assert {:error, :unfenced_write} = Steward.Errors.reason(ash_error)
  end

  test "a write with an expired lease is rejected as :lease_expired" do
    external_id = external_id()
    invoice = create_invoice!(external_id)

    expired_lease = %{token: 1, expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}

    assert {:error, ash_error} =
             Shadows.record_payment(invoice, Decimal.new(10),
               context: %{steward: %{lease: expired_lease}}
             )

    assert {:error, :lease_expired} = Steward.Errors.reason(ash_error)
  end

  test "backend-side drift is rejected as :stale_resource with the backend's current state" do
    external_id = external_id()
    invoice = create_invoice!(external_id)

    assert {:ok, lease} = LeaseProvider.acquire(external_id)
    FakeBackend.simulate_external_write(external_id, %{amount_paid: Decimal.new(999)})

    assert {:error, ash_error} =
             Shadows.record_payment(invoice, Decimal.new(10),
               context: %{steward: %{lease: lease}}
             )

    assert {:error, :stale_resource, remote_state} = Steward.Errors.reason(ash_error)
    assert remote_state.amount_paid == Decimal.new(999)
  end

  test "a fenced write with a valid lease succeeds and updates version/sync_status" do
    external_id = external_id()
    invoice = create_invoice!(external_id)

    assert {:ok, lease} = LeaseProvider.acquire(external_id)

    assert {:ok, updated} =
             Shadows.record_payment(invoice, Decimal.new(10),
               context: %{steward: %{lease: lease}}
             )

    assert Decimal.equal?(updated.amount_paid, Decimal.new(10))
    assert updated.version == 1
    assert updated.sync_status == :synced
  end
end
