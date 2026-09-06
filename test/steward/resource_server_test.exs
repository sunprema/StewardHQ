defmodule Steward.ResourceServerTest do
  @moduledoc """
  Phase 1 definition-of-done test suite (CLAUDE.md): shared/shared
  coexistence, shared/exclusive blocking, exclusive/exclusive queueing,
  crash auto-release, double-release safety.
  """

  use ExUnit.Case, async: true

  alias Steward.ResourceServer

  # Each test gets its own resource id so the process-global
  # ResourceServerSupervisor/Registry never leaks state between tests.
  defp resource_id, do: {:test_resource, make_ref()}

  describe "shared borrows" do
    test "multiple shared borrows coexist" do
      resource = resource_id()

      assert {:ok, ref1} = ResourceServer.acquire(resource, :shared)
      assert {:ok, ref2} = ResourceServer.acquire(resource, :shared)
      assert ref1 != ref2

      assert %{shared: shared, exclusive: nil, queue_length: 0} = ResourceServer.borrows(resource)
      assert Enum.sort(shared) == Enum.sort([ref1, ref2])
    end
  end

  describe "shared vs exclusive" do
    test "an exclusive request blocks while a shared borrow is held, then grants on release" do
      resource = resource_id()
      test_pid = self()

      assert {:ok, shared_ref} = ResourceServer.acquire(resource, :shared)

      spawn(fn ->
        result = ResourceServer.acquire(resource, :exclusive)
        send(test_pid, {:acquired, result})
      end)

      # Give the waiter a moment to queue up.
      Process.sleep(50)
      assert %{queue_length: 1} = ResourceServer.borrows(resource)
      refute_received {:acquired, _}

      assert :ok = ResourceServer.release(resource, shared_ref)

      assert_receive {:acquired, {:ok, _exclusive_ref}}, 1_000
    end

    test "a shared request blocks while an exclusive borrow is held" do
      resource = resource_id()
      test_pid = self()

      assert {:ok, exclusive_ref} = ResourceServer.acquire(resource, :exclusive)

      spawn(fn ->
        result = ResourceServer.acquire(resource, :shared)
        send(test_pid, {:acquired, result})
      end)

      Process.sleep(50)
      refute_received {:acquired, _}

      assert :ok = ResourceServer.release(resource, exclusive_ref)
      assert_receive {:acquired, {:ok, _shared_ref}}, 1_000
    end
  end

  describe "exclusive vs exclusive" do
    test "a second exclusive request queues and is granted in order after release" do
      resource = resource_id()
      test_pid = self()

      assert {:ok, first_ref} = ResourceServer.acquire(resource, :exclusive)

      waiter =
        spawn(fn ->
          result = ResourceServer.acquire(resource, :exclusive)
          send(test_pid, {:acquired, result})

          # Hold the borrow open so the test can observe it before this
          # process exits and auto-releases it.
          receive do
            :release -> :ok
          end
        end)

      Process.sleep(50)
      assert %{queue_length: 1} = ResourceServer.borrows(resource)
      refute_received {:acquired, _}

      assert :ok = ResourceServer.release(resource, first_ref)

      assert_receive {:acquired, {:ok, second_ref}}, 1_000

      # Exactly one exclusive holder at any time: the resource is held
      # again (by the waiter), not free.
      assert %{exclusive: ^second_ref} = ResourceServer.borrows(resource)

      send(waiter, :release)
    end

    test "a queued acquire that outlasts its timeout gets {:error, :timeout} and is dropped" do
      resource = resource_id()

      assert {:ok, _held_ref} = ResourceServer.acquire(resource, :exclusive)
      assert {:error, :timeout} = ResourceServer.acquire(resource, :exclusive, timeout: 100)

      assert %{queue_length: 0} = ResourceServer.borrows(resource)
    end
  end

  describe "crash auto-release" do
    test "killing the holder process releases its borrow" do
      resource = resource_id()
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, _ref} = ResourceServer.acquire(resource, :exclusive)
          send(test_pid, :acquired)

          receive do
            :never -> :unreachable
          end
        end)

      assert_receive :acquired, 1_000
      assert %{exclusive: exclusive_ref} = ResourceServer.borrows(resource)
      refute is_nil(exclusive_ref)

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000

      # The resource server's own monitor must independently notice and
      # release — poll briefly since DOWN delivery order isn't guaranteed
      # relative to our own monitor above.
      assert wait_until(fn -> ResourceServer.borrows(resource).exclusive == nil end)

      assert {:ok, _new_ref} = ResourceServer.acquire(resource, :exclusive)
    end
  end

  describe "concurrency" do
    test "N agents contending for one resource: exactly one exclusive holder at any time" do
      resource = resource_id()
      concurrency = 20
      iterations = 10

      # :ets.update_counter/4 is atomic, so this is a race-free witness of
      # how many processes are simultaneously inside the exclusive section.
      table = :ets.new(:concurrency_witness, [:public, :set])
      :ets.insert(table, {:current, 0})

      1..concurrency
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for _ <- 1..iterations do
            ResourceServer.borrow(resource, :exclusive, fn ->
              current = :ets.update_counter(table, :current, {2, 1})
              if current > 1, do: :ets.insert(table, {:violation, current})
              # Yield briefly so overlapping holders are actually likely
              # if the borrow checker fails to serialize them.
              Process.sleep(1)
              :ets.update_counter(table, :current, {2, -1})
            end)
          end
        end)
      end)
      |> Task.await_many(30_000)

      assert [{:current, 0}] = :ets.lookup(table, :current)
      assert :ets.lookup(table, :violation) == []
    end
  end

  describe "double-release safety" do
    test "releasing the same borrow twice is safe" do
      resource = resource_id()

      assert {:ok, ref} = ResourceServer.acquire(resource, :shared)
      assert :ok = ResourceServer.release(resource, ref)
      assert {:error, :not_borrowed} = ResourceServer.release(resource, ref)
    end

    test "releasing an unknown ref is safe" do
      resource = resource_id()
      assert {:error, :not_borrowed} = ResourceServer.release(resource, make_ref())
    end
  end

  describe "verify_borrow/3 (the Witness Pattern's actual check)" do
    test "a live borrow held by this process on this resource verifies" do
      id = make_ref()

      assert {:ok, token} = ResourceServer.acquire({FakeResource, id}, :exclusive)

      assert {:ok, %{key: {FakeResource, ^id}, mode: :exclusive, holder: holder}} =
               ResourceServer.verify_borrow(token, FakeResource)

      assert holder == self()
    end

    test "a fabricated token is refused" do
      assert {:error, :unborrowed_access} =
               ResourceServer.verify_borrow(make_ref(), FakeResource)
    end

    test "a term that isn't even a reference is refused" do
      assert {:error, :unborrowed_access} =
               ResourceServer.verify_borrow(:trust_me, FakeResource)
    end

    test "a released token stops verifying" do
      resource = {FakeResource, make_ref()}

      assert {:ok, token} = ResourceServer.acquire(resource, :exclusive)
      assert {:ok, _entry} = ResourceServer.verify_borrow(token, FakeResource)

      assert :ok = ResourceServer.release(resource, token)
      assert {:error, :unborrowed_access} = ResourceServer.verify_borrow(token, FakeResource)
    end

    test "a token whose holder died stops verifying, without anyone releasing it" do
      resource = {FakeResource, make_ref()}
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, token} = ResourceServer.acquire(resource, :exclusive)
          send(test_pid, {:token, token})
          Process.sleep(:infinity)
        end)

      assert_receive {:token, token}, 1_000
      assert {:ok, _entry} = ResourceServer.verify_borrow(token, FakeResource, holder)

      Process.exit(holder, :kill)

      assert wait_until(fn ->
               ResourceServer.verify_borrow(token, FakeResource, holder) ==
                 {:error, :unborrowed_access}
             end)
    end

    test "a live token cannot be laundered through another process" do
      resource = {FakeResource, make_ref()}
      test_pid = self()

      assert {:ok, token} = ResourceServer.acquire(resource, :exclusive)

      spawn(fn ->
        send(test_pid, {:verified, ResourceServer.verify_borrow(token, FakeResource)})
      end)

      assert_receive {:verified, {:error, :unborrowed_access}}, 1_000
    end

    test "a borrow on one resource cannot witness another" do
      id = make_ref()
      assert {:ok, token} = ResourceServer.acquire({FakeResource, id}, :exclusive)

      assert {:error, :unborrowed_access} =
               ResourceServer.verify_borrow(token, OtherFakeResource)
    end

    test "a borrow taken on a bare id cannot witness a resource action" do
      assert {:ok, token} = ResourceServer.acquire(make_ref(), :exclusive)
      assert {:error, :unborrowed_access} = ResourceServer.verify_borrow(token, FakeResource)
    end
  end

  describe "borrow/3" do
    test "releases on normal return" do
      resource = resource_id()

      assert :done = ResourceServer.borrow(resource, :exclusive, fn -> :done end)
      assert %{exclusive: nil} = ResourceServer.borrows(resource)
    end

    test "releases even when the function raises" do
      resource = resource_id()

      assert_raise RuntimeError, "boom", fn ->
        ResourceServer.borrow(resource, :exclusive, fn -> raise "boom" end)
      end

      assert %{exclusive: nil} = ResourceServer.borrows(resource)
    end

    test "top-level Steward.borrow/3 delegates" do
      resource = resource_id()
      assert :ok = Steward.borrow(resource, :shared, fn -> :ok end)
    end

    test "an arity-1 function receives the borrow token, ready to witness with" do
      id = make_ref()

      verified =
        Steward.borrow({FakeResource, id}, :exclusive, fn token ->
          %{steward: %{borrow_token: ^token}} = Steward.witness(token)
          ResourceServer.verify_borrow(token, FakeResource)
        end)

      assert {:ok, %{key: {FakeResource, ^id}}} = verified
    end
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
