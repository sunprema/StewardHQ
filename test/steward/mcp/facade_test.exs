defmodule Steward.MCP.FacadeTest do
  @moduledoc """
  Phase 5 MCP facade coverage for `Steward.MCP.Facade` (docs/tech_spec.md
  §8): end-to-end tool registration and dispatch against the real
  `Steward.Test.Examples.Invoice` resource and a real Postgres-backed
  saga — the same proxy model the design settled on: the facade calls
  the backend itself, the agent only ever sees the tool call and its
  structured result.

  Exercises `init/2`/`handle_tool_call/3` directly rather than through
  the actual JSON-RPC/HTTP transport — that wire format is `hermes_mcp`'s
  own already-tested concern, not this project's.
  """

  use Steward.DataCase, async: true

  alias Hermes.Server.Frame
  alias Steward.MCP.Facade
  alias Steward.Test.Borrows
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp account_id, do: Ecto.UUID.generate()

  defp create_invoice!(total \\ Decimal.new(100)) do
    Borrows.creating(Invoice, fn witness ->
      Examples.create_invoice!(account_id(), total, context: witness)
    end)
  end

  defp approve_invoice!(invoice) do
    Borrows.witnessed(Invoice, invoice.id, fn witness ->
      Examples.approve_invoice!(invoice, context: witness)
    end)
  end

  defp init_frame! do
    {:ok, frame} = Facade.init(%{}, Frame.new())
    frame
  end

  describe "init/2" do
    test "registers one tool per non-create capability of every configured resource" do
      %{assigns: %{steward_tools: tools}} = init_frame!()

      assert Map.keys(tools) |> Enum.sort() == [
               "approve_invoice",
               "notify_invoice",
               "pay_invoice",
               "read_invoice"
             ]

      assert tools["pay_invoice"] == {Invoice, :pay, :status}
    end
  end

  describe "handle_tool_call/3 success" do
    test "pays an invoice: acquires the borrow/lease/fencing itself and returns the updated record" do
      invoice = create_invoice!()
      approve_invoice!(invoice)
      frame = init_frame!()

      assert {:reply, response, _frame} =
               Facade.handle_tool_call(
                 "pay_invoice",
                 %{"resource_id" => invoice.id, "amount_paid" => "100"},
                 frame
               )

      refute response.isError
      assert response.structured_content["status"] == "paid"
      assert response.structured_content["amount_paid"] == "100"

      assert {:ok, updated} = Examples.get_invoice(invoice.id)
      assert updated.status == :paid
    end

    test "correctly validates a second call against the invoice's real current state, not its declared initial state" do
      invoice = create_invoice!()
      frame = init_frame!()

      assert {:reply, response, _frame} =
               Facade.handle_tool_call("approve_invoice", %{"resource_id" => invoice.id}, frame)

      refute response.isError
      assert response.structured_content["status"] == "approved"

      # A second, independent call sees the invoice already :approved (via
      # Tool.initial_states/4's live pre-fetch) rather than assuming :draft.
      assert {:reply, response, _frame} =
               Facade.handle_tool_call(
                 "pay_invoice",
                 %{"resource_id" => invoice.id, "amount_paid" => "100"},
                 frame
               )

      refute response.isError
      assert response.structured_content["status"] == "paid"
    end
  end

  describe "handle_tool_call/3 failure" do
    test "an illegal transition comes back as a legible tool-level error, not a crash" do
      invoice = create_invoice!()
      frame = init_frame!()

      assert {:reply, response, _frame} =
               Facade.handle_tool_call(
                 "pay_invoice",
                 %{"resource_id" => invoice.id, "amount_paid" => "100"},
                 frame
               )

      assert response.isError
      assert response.structured_content["reason"] == "invalid_transition"
    end

    test "an unknown tool name fails as a protocol-level error" do
      frame = init_frame!()

      assert {:error, error, _frame} = Facade.handle_tool_call("delete_the_database", %{}, frame)
      assert error.reason == :method_not_found
    end
  end
end
