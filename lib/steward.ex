defmodule Steward do
  @moduledoc """
  Public stewardship API (docs/tech_spec.md §3, §4.1, §8 Phase 1).

  `Steward.ResourceServer` implements the borrow checker; this module is
  the thin public-facing entry point, named per CLAUDE.md's stewardship
  vocabulary convention (`borrow/3`, not "lock"/"unlock").
  """

  @doc "See `Steward.ResourceServer.borrow/3`."
  defdelegate borrow(resource_id, mode, fun), to: Steward.ResourceServer

  @doc """
  Wraps a borrow token as the action context every stewarded Ash action
  requires (spec §4.1's Witness Pattern):

      Steward.borrow({MyApp.Invoice, id}, :exclusive, fn token ->
        MyApp.Billing.pay_invoice(invoice, amount, context: Steward.witness(token))
      end)

  The token is only honoured for the process that acquired it, and only
  while the borrow is held — see `Steward.ResourceServer.verify_borrow/3`.
  """
  @spec witness(reference()) :: %{steward: %{borrow_token: reference()}}
  def witness(borrow_token), do: %{steward: %{borrow_token: borrow_token}}
end
