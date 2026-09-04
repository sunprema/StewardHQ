defmodule Steward.LeaseProviderTest do
  @moduledoc """
  Phase 2 definition-of-done coverage for `Steward.LeaseProvider`:
  acquire/renew/release/expire, fencing-token monotonicity, the renewal
  ceiling, contention, and double-release safety.
  """

  use ExUnit.Case, async: true

  alias Steward.LeaseProvider

  defp resource_id, do: {:test_lease, make_ref()}

  describe "acquire/2" do
    test "grants a lease with a fencing token and rejects a concurrent acquire" do
      resource = resource_id()

      assert {:ok, %{token: token, ref: ref, expires_at: expires_at}} =
               LeaseProvider.acquire(resource)

      assert is_integer(token)
      assert is_reference(ref)
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt

      assert {:error, :lease_held} = LeaseProvider.acquire(resource)
    end

    test "fencing tokens increase monotonically across acquire cycles" do
      resource = resource_id()

      assert {:ok, %{token: token1, ref: ref1}} = LeaseProvider.acquire(resource)
      assert :ok = LeaseProvider.release(resource, ref1)

      assert {:ok, %{token: token2}} = LeaseProvider.acquire(resource)
      assert token2 > token1
    end
  end

  describe "renew/3" do
    test "extends expiry, keeping the same token" do
      resource = resource_id()

      assert {:ok, %{token: token, ref: ref, expires_at: expires_at}} =
               LeaseProvider.acquire(resource, ttl: 200)

      Process.sleep(50)

      assert {:ok, %{token: ^token, expires_at: renewed_expires_at}} =
               LeaseProvider.renew(resource, ref, ttl: 200)

      assert DateTime.compare(renewed_expires_at, expires_at) in [:gt, :eq]
    end

    test "renewing past the ceiling force-expires the lease" do
      resource = resource_id()
      assert {:ok, %{ref: ref}} = LeaseProvider.acquire(resource, ttl: 50)

      assert {:error, :lease_expired} =
               LeaseProvider.renew(resource, ref, ttl: 50, max_duration: 10)

      # The lease is gone: a new acquire succeeds immediately.
      assert {:ok, _lease} = LeaseProvider.acquire(resource)
    end

    test "renewing an unknown or already-expired ref returns :lease_expired" do
      resource = resource_id()
      assert {:error, :lease_expired} = LeaseProvider.renew(resource, make_ref())
    end
  end

  describe "release/2" do
    test "releasing frees the resource for a new acquire" do
      resource = resource_id()
      assert {:ok, %{ref: ref}} = LeaseProvider.acquire(resource)
      assert :ok = LeaseProvider.release(resource, ref)
      assert {:ok, _lease} = LeaseProvider.acquire(resource)
    end

    test "double release is safe" do
      resource = resource_id()
      assert {:ok, %{ref: ref}} = LeaseProvider.acquire(resource)
      assert :ok = LeaseProvider.release(resource, ref)
      assert {:error, :not_leased} = LeaseProvider.release(resource, ref)
    end

    test "releasing an unknown ref is safe" do
      resource = resource_id()
      assert {:error, :not_leased} = LeaseProvider.release(resource, make_ref())
    end
  end

  describe "TTL expiry" do
    test "a lease frees itself on TTL expiry without the holder process exiting" do
      resource = resource_id()
      assert {:ok, _lease} = LeaseProvider.acquire(resource, ttl: 30)

      assert wait_until(fn -> LeaseProvider.current(resource) == nil end)
      assert {:ok, _lease} = LeaseProvider.acquire(resource)
    end
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(15)
      wait_until(fun, attempts - 1)
    end
  end
end
