defmodule Steward.Changes.EnforceFencingTest do
  @moduledoc """
  Phase 2 definition-of-done coverage for `Steward.Changes.EnforceFencing`
  against the real `Steward.Shadows.Invoice` resource: missing lease,
  expired lease, forged lease, backend-side drift, and the happy path
  (docs/tech_spec.md §4.2, §4.4; CLAUDE.md invariant 2).

  Leases here come from a real `Steward.LeaseProvider`, never hand-built.
  The `forged leases` block is the "try to violate the invariant" half of
  CLAUDE.md's testing convention: a lease is checked against the provider
  that issued it, so inventing one — or tampering with the fencing token
  on a real one — cannot get a write to the backend.
  """

  use Steward.DataCase, async: true

  alias Steward.Idempotency
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

  test "a write with a genuinely expired lease is rejected as :lease_expired" do
    external_id = external_id()
    invoice = create_invoice!(external_id)

    assert {:ok, lease} = LeaseProvider.acquire(external_id, ttl: 50)
    Process.sleep(100)
    assert LeaseProvider.current(external_id) == nil

    assert {:error, ash_error} =
             Shadows.record_payment(invoice, Decimal.new(10),
               context: %{steward: %{lease: lease}}
             )

    assert {:error, :lease_expired} = Steward.Errors.reason(ash_error)
  end

  describe "forged leases" do
    test "a hand-built lease map is rejected as :unfenced_write, not honoured" do
      external_id = external_id()
      invoice = create_invoice!(external_id)

      forged = %{token: 999, expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)}

      assert {:error, ash_error} =
               Shadows.record_payment(invoice, Decimal.new(10),
                 context: %{steward: %{lease: forged}}
               )

      assert {:error, :unfenced_write} = Steward.Errors.reason(ash_error)
      assert {:ok, %{version: 0}} = FakeBackend.fetch(external_id)
    end

    test "a released lease no longer fences anything" do
      external_id = external_id()
      invoice = create_invoice!(external_id)

      assert {:ok, lease} = LeaseProvider.acquire(external_id)
      assert :ok = LeaseProvider.release(external_id, lease.ref)

      assert {:error, ash_error} =
               Shadows.record_payment(invoice, Decimal.new(10),
                 context: %{steward: %{lease: lease}}
               )

      assert {:error, :lease_expired} = Steward.Errors.reason(ash_error)
    end

    test "a real lease carrying a tampered fencing token is rejected as :unfenced_write" do
      external_id = external_id()
      invoice = create_invoice!(external_id)

      assert {:ok, lease} = LeaseProvider.acquire(external_id)
      tampered = %{lease | token: lease.token + 1_000}

      assert {:error, ash_error} =
               Shadows.record_payment(invoice, Decimal.new(10),
                 context: %{steward: %{lease: tampered}}
               )

      assert {:error, :unfenced_write} = Steward.Errors.reason(ash_error)
      assert {:ok, %{version: 0}} = FakeBackend.fetch(external_id)
    end

    test "a lease acquired on a different resource cannot fence this one" do
      external_id = external_id()
      invoice = create_invoice!(external_id)

      assert {:ok, other_lease} = LeaseProvider.acquire(external_id())

      assert {:error, ash_error} =
               Shadows.record_payment(invoice, Decimal.new(10),
                 context: %{steward: %{lease: %{other_lease | key: external_id}}}
               )

      assert {:error, :lease_expired} = Steward.Errors.reason(ash_error)
    end
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

  describe "idempotency keys (spec §4.2's phantom-payment defense)" do
    # The nightmare case from spec §4.2: the backend performed the write
    # but the caller never learned it did. The retry that follows must
    # not apply the payment a second time.
    test "retrying with the same key replays the stored result instead of writing twice" do
      external_id = external_id()
      invoice = create_invoice!(external_id)
      key = Steward.Idempotency.step_key(Ash.UUID.generate(), 1)

      assert {:ok, lease} = LeaseProvider.acquire(external_id)
      context = %{steward: %{lease: lease, idempotency_key: key}}

      assert {:ok, first} = Shadows.record_payment(invoice, Decimal.new(10), context: context)

      # `invoice` is deliberately the *pre-write* struct — the stale state
      # a caller retrying an ambiguous failure still holds, whose version
      # the first write has already moved past.
      assert {:ok, replayed} = Shadows.record_payment(invoice, Decimal.new(10), context: context)

      assert first.version == 1
      assert replayed.version == 1
      assert FakeBackend.write_count(external_id) == 1

      assert {:ok, %{version: 1, state: %{amount_paid: amount_paid}}} =
               FakeBackend.fetch(external_id)

      assert Decimal.equal?(amount_paid, Decimal.new(10))
    end

    test "a different key is a different write, not a replay" do
      external_id = external_id()
      invoice = create_invoice!(external_id)
      saga_id = Ash.UUID.generate()

      assert {:ok, lease} = LeaseProvider.acquire(external_id)

      assert {:ok, paid} =
               Shadows.record_payment(invoice, Decimal.new(10),
                 context: %{
                   steward: %{lease: lease, idempotency_key: Idempotency.step_key(saga_id, 1)}
                 }
               )

      assert {:ok, _second} =
               Shadows.record_payment(paid, Decimal.new(20),
                 context: %{
                   steward: %{lease: lease, idempotency_key: Idempotency.step_key(saga_id, 2)}
                 }
               )

      assert FakeBackend.write_count(external_id) == 2
    end

    # Without a key there is nothing to deduplicate against, so the retry
    # is caught by version fencing instead — discoverable, but only after
    # the fact. This is the `idempotency :none` case spec §4.2 answers
    # with the deep-sync repair step rather than with keys.
    test "without a key the same retry is rejected as :stale_resource" do
      external_id = external_id()
      invoice = create_invoice!(external_id)

      assert {:ok, lease} = LeaseProvider.acquire(external_id)
      context = %{steward: %{lease: lease}}

      assert {:ok, _first} = Shadows.record_payment(invoice, Decimal.new(10), context: context)

      assert {:error, ash_error} =
               Shadows.record_payment(invoice, Decimal.new(10), context: context)

      assert {:error, :stale_resource, _remote_state} = Steward.Errors.reason(ash_error)
      assert FakeBackend.write_count(external_id) == 1
    end
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
