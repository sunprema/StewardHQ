defmodule Steward.RepairLoopTest do
  @moduledoc """
  Phase 2 coverage for `Steward.RepairLoop`: converges once the backend
  catches up, and reports `{:error, :repair_failed, _}` once attempts are
  exhausted (docs/tech_spec.md §4.2 "Repair loop").
  """

  use ExUnit.Case, async: true

  alias Steward.RepairLoop
  alias Steward.Test.FakeBackend

  defp resource_id, do: {:test_repair, make_ref()}

  test "converges once the backend reaches the expected state" do
    resource = resource_id()
    FakeBackend.seed(resource, 1, %{status: "pending"})

    task =
      Task.async(fn ->
        Process.sleep(60)
        FakeBackend.simulate_external_write(resource, %{status: "settled"})
      end)

    assert {:ok, %{state: %{status: "settled"}}} =
             RepairLoop.run(FakeBackend, resource, &(&1.status == "settled"),
               max_attempts: 10,
               backoff_ms: 20
             )

    Task.await(task)
  end

  test "reports :repair_failed once attempts are exhausted" do
    resource = resource_id()
    FakeBackend.seed(resource, 1, %{status: "pending"})

    assert {:error, :repair_failed, %{status: "pending"}} =
             RepairLoop.run(FakeBackend, resource, &(&1.status == "settled"),
               max_attempts: 3,
               backoff_ms: 5
             )
  end
end
