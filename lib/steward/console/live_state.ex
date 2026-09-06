defmodule Steward.Console.LiveState do
  @moduledoc """
  Live (in-memory) runtime state for the console: borrows, leases,
  capabilities, agents and channels.

  ## Why this module exists

  `docs/agent_interaction_ux.md` ("Instrumentation required before the live
  views work") records that the runtime cannot yet answer these questions:

    * there are zero `:telemetry.execute/3` calls in the Steward domain, and
      `Steward.PubSub` is started but unused, so nothing can push updates;
    * `Steward.CapabilityRegistry` exposes only `status/1` for a single ref —
      there is no list function;
    * `Steward.ResourceServer.borrows/1` omits holder pids and queue-waiter
      identities;
    * sub-agent instance ids are `{name, make_ref()}` and never persisted.

  Until that instrumentation lands, this module serves a seeded dataset in
  the exact shape the real sources will return, so the screens are complete
  and swapping in live data is a change here and nowhere else. Every public
  function is the seam: `borrow_board/0`, `agent_tree/0`, `capabilities/0`
  and `summary/0` are what the LiveViews call.

  The seed values are the ones drawn in the design canvas (artboards 1f and
  1h), themselves grounded in `docs/cookbook.md` — `acme-inv-1001`,
  `pay_invoice`, refund → restock → notify, and `spawn_agent` channels with
  capacity 1 and a `:reject` overflow policy.

  ## Time

  Seed rows carry a design-time remaining lease and a cycle length rather
  than a fixed timestamp. `expires_at/2` walks the countdown down and wraps
  it, so leases genuinely tick (§4 principle 4, "time is a first-class
  axis") instead of freezing or drifting into large negative numbers. Ages
  and uptimes count up from a boot epoch. None of this survives the swap to
  real telemetry — it exists so the live screens behave like live screens.
  """

  @doc """
  When the runtime started. Live screens must show this next to any empty
  state, so an empty board reads as "nothing is held right now" rather than
  "nothing ever happened" (§4 principle 2).
  """
  def started_at do
    DateTime.add(DateTime.utc_now(), -(2 * 3600 + 14 * 60), :second)
  end

  # Anchor the cycling countdowns to boot, so the first render of a live
  # screen shows exactly the values the design canvas drew and ticks down
  # from there, rather than landing mid-cycle on an arbitrary snapshot.
  defp epoch do
    case :persistent_term.get({__MODULE__, :epoch}, nil) do
      nil ->
        now = DateTime.utc_now()
        :persistent_term.put({__MODULE__, :epoch}, now)
        now

      %DateTime{} = at ->
        at
    end
  end

  defp elapsed, do: DateTime.diff(DateTime.utc_now(), epoch())

  # Remaining seconds on a lease that started with `remaining` and re-cycles
  # every `cycle` seconds, so the board keeps showing a live countdown.
  defp remaining(remaining, cycle) do
    case remaining - Integer.mod(elapsed(), cycle) do
      r when r > 0 -> r
      r -> r + cycle
    end
  end

  defp expires_at(remaining, cycle) do
    DateTime.add(DateTime.utc_now(), remaining(remaining, cycle), :second)
  end

  # A moment `seconds` in the past, for held-since and uptime values.
  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # ------------------------------------------------------------------
  # Borrow board
  # ------------------------------------------------------------------

  @doc """
  Every resource with live state, ordered by soonest expiry.

  Shape mirrors what `Steward.ResourceServer.borrows/1` plus
  `Steward.LeaseProvider.current/1` will return once holder pids and queue
  waiters are exposed (gap 4 in agent_interaction_ux.md).
  """
  def borrow_board do
    [
      %{
        resource: "Invoice",
        resource_id: "acme-inv-1001",
        lease_ttl: 60,
        lease_token: 48,
        expires_at: expires_at(12, 300),
        holders: [
          %{agent: "invoice-runner", pid: "#PID<0.418.0>", mode: :exclusive, since: ago(18)}
        ],
        waiters: [
          %{agent: "pay-worker", pid: "#PID<0.427.0>", mode: :exclusive, since: ago(9)},
          %{agent: nil, pid: "#PID<0.431.0>", mode: :shared, since: ago(4)}
        ]
      },
      %{
        resource: "Order",
        resource_id: "acme-ord-2003",
        lease_ttl: 90,
        lease_token: 13,
        expires_at: expires_at(58, 300),
        holders: [
          %{agent: "order-canceller", pid: "#PID<0.390.0>", mode: :exclusive, since: ago(62)}
        ],
        waiters: [
          %{agent: "restock-worker", pid: "#PID<0.441.0>", mode: :exclusive, since: ago(31)}
        ]
      },
      %{
        resource: "Expense",
        resource_id: "exp-7781",
        lease_ttl: 185,
        lease_token: 3,
        expires_at: expires_at(165, 300),
        holders: [
          %{agent: "approve-specialist", pid: "#PID<0.455.0>", mode: :exclusive, since: ago(38)}
        ],
        waiters: []
      },
      %{
        resource: "Order",
        resource_id: "acme-ord-2002",
        lease_ttl: 265,
        lease_token: 21,
        expires_at: expires_at(250, 300),
        holders: [
          %{agent: "audit-reader", pid: "#PID<0.377.0>", mode: :shared, since: ago(120)},
          %{agent: "audit-reader", pid: "#PID<0.381.0>", mode: :shared, since: ago(100)},
          %{agent: nil, pid: "#PID<0.402.0>", mode: :shared, since: ago(50)}
        ],
        waiters: []
      },
      %{
        resource: "StripeInvoice",
        resource_id: "acme-stripe-1001",
        lease_ttl: 298,
        lease_token: 7,
        expires_at: expires_at(292, 300),
        holders: [
          %{agent: "stripe-reconciler", pid: "#PID<0.466.0>", mode: :shared, since: ago(8)}
        ],
        waiters: []
      }
    ]
  end

  @doc "Total resources the runtime knows about, live or not (for the board footer)."
  def known_resource_count, do: 12

  @doc "Warn threshold for a lease countdown, in seconds (§6.1 attention list)."
  def expiring_threshold, do: 30

  @doc "Warn threshold for a queue waiter's age, in seconds."
  def queue_threshold, do: 20

  # ------------------------------------------------------------------
  # Capabilities
  # ------------------------------------------------------------------

  @doc """
  Active capability ledger rows. Backed by `Steward.CapabilityRegistry`
  once it grows a list function (gap 3).
  """
  def capabilities do
    [
      %{
        ref: "cap_88d0a1f24c6b41d9e412",
        action: "approve",
        resource: "Expense",
        resource_id: "exp-7781",
        holder: "approve-specialist",
        status: :active,
        moved_from: "expense-supervisor",
        moved_at: ago(38),
        issued_at: ago(44),
        saga_id: "sg_71be4a02c1d8f6390c33"
      },
      %{
        ref: "cap_5f31bb0947ac2d18a7e0",
        action: "pay_invoice",
        resource: "Invoice",
        resource_id: "acme-inv-1001",
        holder: "pay-worker",
        status: :active,
        moved_from: nil,
        moved_at: nil,
        issued_at: ago(9),
        saga_id: "sg_9c41d7e8b2a0553fe7b2"
      },
      %{
        ref: "cap_c07e29d418fb6a35b1c2",
        action: "capture",
        resource: "Invoice",
        resource_id: "acme-inv-1001",
        holder: "invoice-runner",
        status: :active,
        moved_from: nil,
        moved_at: nil,
        issued_at: ago(724),
        saga_id: "sg_9c41d7e8b2a0553fe7b2"
      },
      %{
        ref: "cap_2ab5901e7fd3c46680aa",
        action: "restock",
        resource: "Order",
        resource_id: "acme-ord-2003",
        holder: "restock-worker",
        status: :active,
        moved_from: nil,
        moved_at: nil,
        issued_at: ago(31),
        saga_id: "sg_b3c7e5104da29817f221"
      },
      %{
        ref: "cap_6d4488ac03e51b92f7d1",
        action: "cancel",
        resource: "Order",
        resource_id: "acme-ord-2003",
        holder: "order-canceller",
        status: :active,
        moved_from: nil,
        moved_at: nil,
        issued_at: ago(62),
        saga_id: "sg_b3c7e5104da29817f221"
      }
    ]
  end

  # ------------------------------------------------------------------
  # Agent tree
  # ------------------------------------------------------------------

  @doc """
  Parent agent → channel → sub-agent hierarchy.

  Backed by `Task.Supervisor.children/1` and
  `Steward.ChannelServer.inspect_state/3` once sub-agent identity is
  persisted (gap 5) and the exit summary is recorded.

  Exited nodes stay in the list with their release summary: that summary is
  the visible proof of invariant 4 (no capability outlives its plan), which
  §6.5 asks the screen to demonstrate.
  """
  def agent_tree do
    [
      %{
        agent: "expense-supervisor",
        pid: "#PID<0.352.0>",
        kind: :parent,
        plan_id: "pl_1a77c0e4",
        state: :alive,
        uptime: 252,
        borrows: 0,
        capabilities: 0,
        saga_id: "sg_71be4a02c1d8f6390c33",
        channels: [
          %{
            name: "spawn",
            queued: 0,
            capacity: 1,
            overflow: :reject,
            closed: false,
            message: "task",
            children: [
              %{
                agent: "approve-specialist",
                pid: "#PID<0.455.0>",
                kind: :sub_agent,
                state: :alive,
                note: nil,
                uptime: 38,
                borrows: 1,
                capabilities: 1,
                saga_id: "sg_71be4a02c1d8f6390c33"
              }
            ]
          }
        ]
      },
      %{
        agent: "invoice-runner",
        pid: "#PID<0.418.0>",
        kind: :parent,
        plan_id: "pl_9c02be51",
        state: :alive,
        uptime: 724,
        borrows: 1,
        capabilities: 2,
        saga_id: "sg_9c41d7e8b2a0553fe7b2",
        channels: [
          %{
            name: "spawn",
            queued: 0,
            capacity: 1,
            overflow: :reject,
            closed: false,
            message: "task",
            children: [
              %{
                agent: "pay-worker",
                pid: "#PID<0.427.0>",
                kind: :sub_agent,
                state: :alive,
                note: {:waiting_on, "acme-inv-1001", nil},
                uptime: 9,
                borrows: 0,
                capabilities: 1,
                saga_id: "sg_9c41d7e8b2a0553fe7b2"
              }
            ]
          },
          %{
            name: "spawn",
            queued: 0,
            capacity: 1,
            overflow: :reject,
            closed: true,
            message: "task",
            children: [
              %{
                agent: "verify-worker",
                pid: "#PID<0.409.0>",
                kind: :sub_agent,
                state: :exited,
                note: {:released, 1, 1},
                exited_ago: 20,
                uptime: 0,
                borrows: 0,
                capabilities: 0,
                saga_id: "sg_54aa3e19b7c02d64c8d0"
              }
            ]
          }
        ]
      },
      %{
        agent: "order-canceller",
        pid: "#PID<0.390.0>",
        kind: :parent,
        plan_id: "pl_b3f81d90",
        state: :alive,
        uptime: 62,
        borrows: 1,
        capabilities: 1,
        saga_id: "sg_b3c7e5104da29817f221",
        channels: [
          %{
            name: "spawn",
            queued: 0,
            capacity: 1,
            overflow: :reject,
            closed: false,
            message: "task",
            children: [
              %{
                agent: "restock-worker",
                pid: "#PID<0.441.0>",
                kind: :sub_agent,
                state: :alive,
                note: {:waiting_on, "acme-ord-2003", 31},
                uptime: 31,
                borrows: 0,
                capabilities: 1,
                saga_id: "sg_b3c7e5104da29817f221"
              },
              %{
                agent: "refund-worker",
                pid: "#PID<0.436.0>",
                kind: :sub_agent,
                state: :exited,
                note: {:released, 0, 1},
                exited_ago: 55,
                uptime: 0,
                borrows: 0,
                capabilities: 0,
                saga_id: "sg_b3c7e5104da29817f221"
              }
            ]
          }
        ]
      }
    ]
  end

  @doc "How long an exited node stays visible before it is dropped (§6.5, open question 4)."
  def exit_visibility_window, do: 60

  @doc "Flatten the tree into `{depth, node}` pairs for the nested-list rendering."
  def flatten(tree) do
    Enum.flat_map(tree, &flatten_node(&1, 0))
  end

  defp flatten_node(node, depth) do
    channels = Map.get(node, :channels, [])

    [{depth, :agent, node}] ++
      Enum.flat_map(channels, fn channel ->
        [{depth + 1, :channel, channel}] ++
          Enum.flat_map(Map.get(channel, :children, []), &flatten_node(&1, depth + 2))
      end)
  end

  @doc "Look up one agent node anywhere in the tree by name."
  def find_agent(name) do
    agent_tree() |> flatten() |> Enum.find_value(fn
      {_d, :agent, %{agent: ^name} = node} -> node
      _ -> nil
    end)
  end

  @doc "The parent agent of a named node, or nil for a root."
  def parent_of(name) do
    Enum.find_value(agent_tree(), fn parent ->
      child? =
        parent
        |> Map.get(:channels, [])
        |> Enum.flat_map(&Map.get(&1, :children, []))
        |> Enum.any?(&(&1.agent == name))

      if child?, do: parent.agent
    end)
  end

  @doc "The channel a named sub-agent was spawned through."
  def channel_of(name) do
    Enum.find_value(agent_tree(), fn parent ->
      Enum.find(Map.get(parent, :channels, []), fn channel ->
        Enum.any?(Map.get(channel, :children, []), &(&1.agent == name))
      end)
    end)
  end

  @doc "Borrows and capabilities a named agent currently holds."
  def holdings(name) do
    borrows =
      for row <- borrow_board(),
          holder <- row.holders,
          holder.agent == name do
        %{
          resource: row.resource,
          resource_id: row.resource_id,
          mode: holder.mode,
          lease_token: row.lease_token,
          expires_at: row.expires_at,
          since: holder.since
        }
      end

    %{borrows: borrows, capabilities: Enum.filter(capabilities(), &(&1.holder == name))}
  end

  # ------------------------------------------------------------------
  # Shadow records
  # ------------------------------------------------------------------

  @doc """
  Shadow records whose cache disagrees with the backend.

  The Shadow records screen itself is designed but not built, so only the
  rows the overview attention list needs are seeded here. Real sync state
  exists today in `shadow_invoices`; per-attempt repair history is the gap
  `Steward.RepairLoop` leaves open (it is a stateless polling loop with no
  observability).
  """
  def conflicted_shadows do
    [
      %{
        resource: "Order",
        resource_id: "acme-ord-2003",
        sync_status: :conflicted,
        cached_version: 3,
        backend_version: 4,
        synced_at: ago(240)
      }
    ]
  end

  # ------------------------------------------------------------------
  # Summary (overview tiles)
  # ------------------------------------------------------------------

  @doc "Counts for the overview tiles and the sidebar badges."
  def summary do
    board = borrow_board()
    holders = Enum.flat_map(board, & &1.holders)
    waiters = Enum.flat_map(board, & &1.waiters)
    caps = capabilities()
    nodes = agent_tree() |> flatten() |> Enum.filter(&match?({_, :agent, _}, &1))

    alive = Enum.count(nodes, fn {_d, _t, n} -> n.state == :alive end)
    parents = Enum.count(nodes, fn {_d, _t, n} -> n.state == :alive and n.kind == :parent end)

    %{
      borrows: length(holders),
      shared: Enum.count(holders, &(&1.mode == :shared)),
      exclusive: Enum.count(holders, &(&1.mode == :exclusive)),
      waiters: length(waiters),
      oldest_waiter:
        waiters
        |> Enum.map(&DateTime.diff(DateTime.utc_now(), &1.since))
        |> Enum.max(fn -> nil end),
      capabilities: length(caps),
      capabilities_moved_recently:
        Enum.count(caps, &(&1.moved_at && DateTime.diff(DateTime.utc_now(), &1.moved_at) < 60)),
      agents: alive,
      agent_parents: parents,
      agent_subs: alive - parents,
      agents_exited: Enum.count(nodes, fn {_d, _t, n} -> n.state == :exited end),
      resources_live: length(board),
      resources_known: known_resource_count()
    }
  end
end
