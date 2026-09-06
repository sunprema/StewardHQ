defmodule Steward.Resource.RequireWitnessTest do
  @moduledoc """
  Phase 3 definition-of-done coverage for the Witness Pattern
  (docs/tech_spec.md §4.1, §4.4; CLAUDE.md invariant 1: "No unwitnessed
  access... There is no bypass path, including from our own internal
  code"), exercised end to end against `Steward.Test.Examples.Invoice`
  rather than mocked.

  Every borrow here is a real `Steward.ResourceServer` borrow. The
  "tries to violate the invariant" half of CLAUDE.md's testing convention
  is the `forged witnesses` block: a token has to be one this process
  actually holds on this resource, or the action is refused exactly as if
  no token had been offered.
  """

  use ExUnit.Case, async: true

  alias Steward.Test.Borrows
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp create_invoice! do
    Borrows.creating(Invoice, fn witness ->
      Examples.create_invoice!(Ecto.UUID.generate(), Decimal.new(100), context: witness)
    end)
  end

  describe "mutating actions (create/update/generic)" do
    test "create without a borrow_token is rejected as :unborrowed_access" do
      assert {:error, error} = Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100))
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "create under a real borrow succeeds" do
      assert %{status: :draft} = create_invoice!()
    end

    test "update without a borrow_token is rejected as :unborrowed_access" do
      invoice = create_invoice!()

      assert {:error, error} = Examples.approve_invoice(invoice)
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "update under a real borrow succeeds, and there is no bypass via direct Ash calls" do
      invoice = create_invoice!()

      assert {:error, direct_error} =
               invoice
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update()

      assert {:error, :unborrowed_access} = Steward.Errors.reason(direct_error)

      approved =
        Borrows.witnessed(Invoice, invoice.id, fn witness ->
          Examples.approve_invoice!(invoice, context: witness)
        end)

      assert approved.status == :approved
    end
  end

  describe "forged witnesses" do
    test "a borrow_token this process never acquired is rejected" do
      invoice = create_invoice!()

      assert {:error, error} =
               Examples.approve_invoice(invoice, context: Steward.witness(make_ref()))

      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "a non-reference term offered as a borrow_token is rejected" do
      invoice = create_invoice!()

      assert {:error, error} =
               Examples.approve_invoice(invoice, context: Steward.witness(:trust_me))

      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "a real token whose borrow has already been released is rejected" do
      invoice = create_invoice!()

      # Capture a token that was genuinely issued, then let it lapse.
      witness =
        Borrows.witnessed(Invoice, invoice.id, fn witness -> witness end)

      assert {:error, error} = Examples.approve_invoice(invoice, context: witness)
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "a live borrow held by another process cannot witness this one's action" do
      invoice = create_invoice!()
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, token} = Steward.ResourceServer.acquire({Invoice, invoice.id}, :exclusive)
          send(test_pid, {:token, token})

          receive do
            :release -> :ok
          end
        end)

      assert_receive {:token, token}, 1_000

      assert {:error, error} = Examples.approve_invoice(invoice, context: Steward.witness(token))
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)

      send(holder, :release)
    end

    test "a live borrow on a different resource cannot witness this one's action" do
      invoice = create_invoice!()

      result =
        Steward.borrow({Steward.Shadows.Invoice, invoice.id}, :exclusive, fn token ->
          Examples.approve_invoice(invoice, context: Steward.witness(token))
        end)

      assert {:error, error} = result
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end
  end

  describe "read actions" do
    test "reads are not witnessed (invariant 1 is scoped to changeset context)" do
      invoice = create_invoice!()

      assert {:ok, fetched} = Examples.get_invoice(invoice.id)
      assert fetched.id == invoice.id
    end
  end
end
