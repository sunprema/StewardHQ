# Agent Interaction UX — Proposed Views

Status: proposal (2026-09-05). Not yet implemented.

This document lists the views we want for inspecting how AI agents interact with the
stewardship runtime, what data backs each view today, and what instrumentation must be
added before the live views can work. It is grounded in the current code, not the roadmap:
where the runtime does not yet expose something, that is called out as a gap.

Cross-references: `docs/tech_spec.md` §4 (Four Guarantees), §5 (System Architecture),
§7 (Execution Flow).

## Mount point

LiveView is already wired (`socket "/live"` in the endpoint) but no LiveViews exist. The
router has an empty `ash_authentication_live_session :authenticated_routes` block; that is
the natural place to mount these views. They would be the first authenticated surface in the
app. Note the MCP route under `/mcp` has no auth today; mounting the views behind
AshAuthentication does not change that.

## Views, in build order

### 1. Interaction timeline (per saga)

The core "what did the agent do" view. One row per saga, expanding to its steps with
resource, resource id, action, status, disposition, result or error, and timestamps.

- **Backed by:** `sagas` and `saga_steps` tables (`Steward.Sagas.list_sagas/0`, the
  `SagaStep` resource via the `:saga` relationship).
- **Why first:** every MCP tool call produces exactly one saga row and one step row through
  `Steward.SagaExecutor.execute/2`. This is currently the only durable trace of an agent
  interaction, and it needs no new instrumentation.
- **Shows:** guarantee 4.3 (atomicity) and 4.4 (legibility): the step outcome and the
  capability disposition (`:consumed | :survived | :dropped`) recorded per error type.

### 2. Live borrow board

A grid of every resource id currently held: mode (shared or exclusive), holder, queue depth
and waiters, lease fencing token and time-to-expiry.

- **Backed by:** enumerating `Steward.Registry` (keys are `resource_id`,
  `{:lease, resource_id}`, `{:channel, ...}`), then `Steward.ResourceServer.borrows/1` and
  `Steward.LeaseProvider.current/1` per resource.
- **Purpose:** the "is anything stuck" view, and the one that makes the borrow-checker
  thesis visible (guarantee 4.1, isolation).
- **Gap:** `borrows/1` omits holder pids and queue-waiter identities (see below).

### 3. Capability ledger

Lifecycle of each capability token: issued, moved, consumed, expired, with holder pid and
the plan it belongs to. Directly demonstrates linearity: a moved capability shows as
consumed at the sender and `{:error, :capability_moved}` on reuse.

- **Backed by:** `Steward.CapabilityRegistry` state (`entries: %{ref => %{status, holder,
  monitor_ref}}`).
- **Gap:** only `status/1` for a single ref is exposed. A list function is required.
- **Purpose:** the highest-value view for reviewers who doubt the safety model.

### 4. Agent tree

Supervisor and sub-agent hierarchy: which task processes are alive, which channel instance
spawned them, and which borrows and capabilities each holds. When a process dies the view
should show the automatic release happening (invariant 4: no capability outlives its plan).

- **Backed by:** `Task.Supervisor.children(Steward.SpawnAgent.TaskSupervisor)`,
  `Steward.ChannelServer.inspect_state/3`, and cross-referencing holder pids from views 2
  and 3.
- **Gap:** sub-agent instance ids are `{name, make_ref()}` and never persisted, so the
  timeline cannot attribute steps to a sub-agent after the fact unless the saga step
  records the spawning instance. `inspect_state/3` also omits send/receive waiter counts.

### 5. Drift and reconciliation view

Shadow records with `sync_status`, `version`, `synced_at`, plus a feed of repair-loop
attempts. Shows "shadow state is a cache, never truth" (guarantee 4.2) and surfaces stale
or conflicted records.

- **Backed by:** `shadow_invoices` table today.
- **Gap:** `Steward.RepairLoop.run/4` is a stateless polling loop with no per-attempt
  observability. Needs telemetry per attempt.

### 6. Error taxonomy panel

Counts and recent examples of each structured error reason (`:unborrowed_access`,
`:unfenced_write`, `:lease_expired`, `:stale_resource`, `:invalid`), with which agent and
tool triggered them. Useful for tuning agent prompts against the spec §4.4 taxonomy.

- **Backed by:** `saga_steps.error` for durable history; a telemetry feed for live counts.
- **Gap:** depends on the telemetry work below.

### 7. Plan preview and validator result

Paste or select a plan, see the step graph, and see the `Steward.PlanValidator` verdict,
including `{:error, :irreversible_before_fallible, step_id}`. A dev tool rather than a
monitor, but the clearest way to explain invariant 6 to a new reader.

- **Backed by:** `Steward.PlanValidator` directly. No runtime state needed.

## Instrumentation required before the live views work

There are zero `:telemetry.execute/3` calls in the Steward domain today. The only
telemetry is what Phoenix, Ecto and Oban emit. `Steward.PubSub` is started but unused.

1. **Add domain telemetry events** for: borrow acquire / release / queue / auto-release,
   lease grant / renew / expiry, capability issue / move / consume / drop / expire, saga and
   step transitions, repair-loop attempts, and MCP tool call start / stop / error.
2. **Forward those events onto `Steward.PubSub`** from one handler so every LiveView gets
   push updates without polling. Add the domain metrics to `StewardWeb.Telemetry` so the
   dev LiveDashboard shows them as well.
3. **`Steward.CapabilityRegistry`:** add a list/dump function over `entries`.
4. **`Steward.ResourceServer.borrows/1`:** include holder pids and queue waiters (mode and
   holder pid per waiter).
5. **Saga steps:** record the spawning channel instance or agent name so history can be
   attributed to a sub-agent.

The strongest single instrumentation point is the MCP facade tool-call handler
(`Steward.MCP.Facade`), since every agent interaction funnels through it into the saga
executor. Instrument there first, then the resource server, then build views 1 and 2 before
anything else.

## Design notes

- **Durable vs ephemeral.** Sagas and steps survive restarts; borrows, leases, capabilities
  and channels are in-memory only. The live views should say "no live state" explicitly
  rather than show an empty board as if nothing happened.
- **Read-only.** These views observe; they must not offer release, move or retry buttons
  that bypass the runtime paths. Any such action would violate invariant 1 (no unwitnessed
  access) from the UI side.
- **Not authorization.** The views show stewardship state, not who is permitted to do what.
  Keep RBAC concerns out of them, per the project's "stewardship is not authz" rule.
