defmodule Steward.IdempotencyTest do
  @moduledoc """
  Phase 2 coverage for `Steward.Idempotency`: key derivation, key
  uniqueness, and the header/body_field/none injection modes
  (docs/tech_spec.md §4.2, §6).
  """

  use ExUnit.Case, async: true

  alias Steward.Idempotency
  alias Steward.Sagas.PlanCodec

  test "generate_key/0 produces unique keys" do
    keys = for _ <- 1..100, do: Idempotency.generate_key()
    assert Enum.uniq(keys) == keys
  end

  describe "step_key/2" do
    test "is stable: the same saga step derives the same key every time" do
      assert Idempotency.step_key("saga-1", "step-1") == Idempotency.step_key("saga-1", "step-1")
    end

    test "distinguishes steps within a saga, and the same step across sagas" do
      assert Idempotency.step_key("saga-1", "a") != Idempotency.step_key("saga-1", "b")
      assert Idempotency.step_key("saga-1", "a") != Idempotency.step_key("saga-2", "a")
    end

    test "handles the integer step ids plans actually use" do
      assert Idempotency.step_key("saga-1", 1) != Idempotency.step_key("saga-1", 2)
      assert Idempotency.step_key("saga-1", 1) == Idempotency.step_key("saga-1", 1)
    end

    # The point of deriving rather than generating: a saga resumed in a
    # new process, from its persisted plan, must send the key its first
    # attempt sent — otherwise the retry after an ambiguous timeout is a
    # second payment, not a retry.
    test "survives a PlanCodec round trip, so a resumed saga replays the same key" do
      saga_id = Ash.UUID.generate()

      step = %{
        id: Ash.UUID.generate(),
        resource: Steward.Test.Examples.Invoice,
        resource_id: Ash.UUID.generate(),
        action: :pay,
        observed_at: DateTime.utc_now()
      }

      before_key = Idempotency.step_key(saga_id, step.id)
      [decoded] = [step] |> PlanCodec.encode() |> PlanCodec.decode()

      assert Idempotency.step_key(saga_id, decoded.id) == before_key
    end
  end

  test "inject/4 with :header mode sets the default header name" do
    key = Idempotency.generate_key()
    assert %{headers: %{"Idempotency-Key" => ^key}} = Idempotency.inject(%{}, key, :header)
  end

  test "inject/4 with :header mode respects a custom header name and merges with existing headers" do
    key = Idempotency.generate_key()
    request = %{headers: %{"Content-Type" => "application/json"}}

    assert %{headers: %{"Content-Type" => "application/json", "X-Idem" => ^key}} =
             Idempotency.inject(request, key, :header, name: "X-Idem")
  end

  test "inject/4 with :body_field mode sets the default field name" do
    key = Idempotency.generate_key()
    assert %{body: %{"idempotency_key" => ^key}} = Idempotency.inject(%{}, key, :body_field)
  end

  test "inject/4 with :none mode is a no-op" do
    key = Idempotency.generate_key()
    assert %{} == Idempotency.inject(%{}, key, :none)
  end
end
