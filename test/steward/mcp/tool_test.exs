defmodule Steward.MCP.ToolTest do
  @moduledoc """
  Phase 5 MCP facade coverage for `Steward.MCP.Tool`: the pure
  translation between an MCP tool call and a single-step plan
  (docs/tech_spec.md §8 "each MCP tool call is auto-wrapped as a
  single-step plan"), tested without a running `Hermes.Server`.
  """

  use ExUnit.Case, async: true

  alias Steward.MCP.Tool
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp account_id, do: Ecto.UUID.generate()

  defp create_invoice!(total \\ Decimal.new(100)) do
    Examples.create_invoice!(account_id(), total,
      context: %{steward: %{borrow_token: make_ref()}}
    )
  end

  describe "name/2" do
    test "matches the spec's own literal example: pay + Invoice -> pay_invoice" do
      assert Tool.name(Invoice, :pay) == "pay_invoice"
    end
  end

  describe "input_schema/2" do
    test "always requires resource_id" do
      assert %{resource_id: {:required, :string}} = Tool.input_schema(Invoice, :approve)
    end

    test "adds one field per the action's declared arguments, required matching allow_nil?" do
      schema = Tool.input_schema(Invoice, :pay)
      assert %{amount_paid: {:required, :string}} = schema
    end

    test "an action with no arguments only carries resource_id" do
      assert Tool.input_schema(Invoice, :approve) == %{resource_id: {:required, :string}}
    end
  end

  describe "build_step/4" do
    test "builds a single-step plan carrying the tool call's resource_id and args" do
      step = Tool.build_step(Invoice, :pay, "inv-1", %{"amount_paid" => "100"})

      assert step.resource == Invoice
      assert step.resource_id == "inv-1"
      assert step.action == :pay
      assert step.args == %{"amount_paid" => "100"}
      assert %DateTime{} = step.observed_at
    end

    test "observed_at is always ~now — a one-shot call has no earlier observation to distrust" do
      step = Tool.build_step(Invoice, :pay, "inv-1", %{})
      assert DateTime.diff(DateTime.utc_now(), step.observed_at, :millisecond) < 1_000
    end
  end

  describe "initial_states/4" do
    test "fetches the record's real current state for a capability that is a declared transition" do
      invoice = create_invoice!()

      assert Tool.initial_states(Invoice, :pay, invoice.id, :status) == %{
               {Invoice, invoice.id} => :draft
             }
    end

    test "reflects a state change already made outside this call" do
      invoice = create_invoice!()
      Examples.approve_invoice!(invoice, context: %{steward: %{borrow_token: make_ref()}})

      assert Tool.initial_states(Invoice, :pay, invoice.id, :status) == %{
               {Invoice, invoice.id} => :approved
             }
    end

    test "is a no-op for a capability that isn't a declared state transition" do
      invoice = create_invoice!()
      assert Tool.initial_states(Invoice, :read, invoice.id, :status) == %{}
    end

    test "is a no-op when the resource_id doesn't exist" do
      assert Tool.initial_states(Invoice, :pay, Ecto.UUID.generate(), :status) == %{}
    end
  end

  describe "serialize_result/1" do
    test "converts an Ash resource struct's public attributes to a JSON-safe map" do
      invoice = create_invoice!(Decimal.new(100))
      result = Tool.serialize_result(invoice)

      assert result["id"] == invoice.id
      assert result["status"] == "draft"
      assert result["total_amount"] == "100"
    end

    test "falls back to a bare {\"result\" => ...} shape for a non-struct value" do
      assert Tool.serialize_result(:sent) == %{"result" => "sent"}
    end
  end

  describe "error_payload/1" do
    test "unwraps a plan-validator failure" do
      assert Tool.error_payload({:error, :invalid_transition, :draft}) == %{
               "reason" => "invalid_transition",
               "detail" => ":draft"
             }
    end

    test "unwraps a borrow-acquisition failure" do
      error = {:error, {:borrow_failed, {Invoice, "inv-1"}, :borrow_conflict}}

      assert %{"reason" => "borrow_failed", "detail" => detail} = Tool.error_payload(error)
      assert detail["resource"] =~ "Invoice"
      assert detail["resource_id"] == "inv-1"
    end

    test "unwraps a Reactor-wrapped step failure via the shared :error field" do
      error =
        {:error,
         %Reactor.Error.Invalid{
           errors: [
             %Reactor.Error.Invalid.RunStepError{error: {:invalid_transition, :draft}, step: nil}
           ]
         }}

      assert Tool.error_payload(error) == %{
               "reason" => "invalid_transition",
               "detail" => ":draft"
             }
    end

    test "unwraps a bare atom reason (e.g. :lease_held) with no detail" do
      error =
        {:error,
         %Reactor.Error.Invalid{
           errors: [%Reactor.Error.Invalid.RunStepError{error: :lease_held, step: nil}]
         }}

      assert Tool.error_payload(error) == %{"reason" => "lease_held"}
    end
  end
end
