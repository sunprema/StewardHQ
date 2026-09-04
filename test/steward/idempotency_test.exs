defmodule Steward.IdempotencyTest do
  @moduledoc """
  Phase 2 coverage for `Steward.Idempotency`: key uniqueness and the
  header/body_field/none injection modes (docs/tech_spec.md §4.2, §6).
  """

  use ExUnit.Case, async: true

  alias Steward.Idempotency

  test "generate_key/0 produces unique keys" do
    keys = for _ <- 1..100, do: Idempotency.generate_key()
    assert Enum.uniq(keys) == keys
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
