defmodule Steward.Resource.RequireWitnessTest do
  @moduledoc """
  Phase 3 definition-of-done coverage for the Witness Pattern
  (docs/tech_spec.md §4.1, §4.4; CLAUDE.md invariant 1: "No unwitnessed
  access... There is no bypass path, including from our own internal
  code"), exercised end to end against `Steward.Test.Examples.Invoice`
  rather than mocked.
  """

  use ExUnit.Case, async: true

  alias Steward.Test.Examples

  defp token, do: %{steward: %{borrow_token: make_ref()}}

  describe "mutating actions (create/update/generic)" do
    test "create without a borrow_token is rejected as :unborrowed_access" do
      assert {:error, error} = Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100))
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "create with a borrow_token in context succeeds" do
      assert {:ok, invoice} =
               Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100), context: token())

      assert invoice.status == :draft
    end

    test "update without a borrow_token is rejected as :unborrowed_access" do
      {:ok, invoice} =
        Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100), context: token())

      assert {:error, error} = Examples.approve_invoice(invoice)
      assert {:error, :unborrowed_access} = Steward.Errors.reason(error)
    end

    test "update with a borrow_token in context succeeds and there is no bypass via direct Ash calls" do
      {:ok, invoice} =
        Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100), context: token())

      assert {:error, direct_error} =
               invoice
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update()

      assert {:error, :unborrowed_access} = Steward.Errors.reason(direct_error)

      assert {:ok, approved} = Examples.approve_invoice(invoice, context: token())
      assert approved.status == :approved
    end
  end

  describe "read actions" do
    test "reads are not witnessed (invariant 1 is scoped to changeset context)" do
      {:ok, invoice} =
        Examples.create_invoice(Ecto.UUID.generate(), Decimal.new(100), context: token())

      assert {:ok, fetched} = Examples.get_invoice(invoice.id)
      assert fetched.id == invoice.id
    end
  end
end
