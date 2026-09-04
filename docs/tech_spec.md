Technical Specification: StewardHQ
Version: 2.3 Concept: A Stewardship Runtime — safe custody of business resources in agentic systems Stack: Elixir, Ash Framework, Spark DSL, OTP (BEAM), Reactor Elixir namespace: Steward.\*

1. Executive Summary
   StewardHQ is a Resource Governance Gateway built on a single idea: a steward is someone entrusted with the management of another's property. AI agents should never own business resources — invoices, orders, money, customer data. StewardHQ holds custody on the enterprise's behalf and grants agents temporary, bounded stewardship: the right to act on a resource, under explicit obligations, for a limited time.

Inspired by Rust's ownership philosophy — but not bound to its literal mechanics — it makes illegal agent states unrepresentable and time-bounds everything else. Enterprises can hook legacy APIs into an agentic ecosystem without risking logical corruption, race conditions, partial failures, or unauthorized state transitions.

Core thesis: Agents propose; the steward disposes. Agents generate plans, but the StewardHQ engine validates, executes, and — when things go wrong — unwinds them. The resources are being protected from the agents, not the other way around.

2. Design Philosophy
   Rust is the inspiration, not the blueprint. Three ideas carry over:

Ownership mindset. Every resource has exactly one clear holder at a time. Delegation transfers rights; it never copies them.
Locks as leases. The right to mutate is a timeboxed grant. Expiry is a normal, expected event — not an exception.
Async discipline. Plan steps are awaitable and cancellable, and nothing outlives the plan that spawned it.
A fourth idea borrowed from Rust's ecosystem strategy: StewardHQ defines the semantics; runtimes are swappable. Like Rust shipping the Future trait while Tokio ships the executor, StewardHQ owns the safety language and lets third parties provide lock backends, agent protocols, persistence layers, and API adapters. (See §9 — deliberately deferred to v2+.)

3. The Three Core Primitives
   Everything in StewardHQ hangs off three primitives.

3.1 own — Linear Ownership & Capability Movement
Every protected resource has one holder at a time. Capabilities are consumable tokens with move semantics:

When a supervisor agent spawns a sub-agent, capabilities are moved into the child task. The parent's copy is consumed; further use yields {:error, :capability_moved}.
Linear capabilities (consumption: :linear) are consumed on use — a :pay right can be exercised exactly once.
This affine-capability model cleanly solves the confused-deputy problem in multi-agent trees: no two tasks can ever hold the same right.

3.2 lease(ttl) — Grants of Stewardship
Agents don't "acquire locks" — they are granted stewardship of a resource for a lease term. Mutation requires such a grant from a lock provider, with an explicit timeframe (e.g., 10 seconds):

Fencing tokens. Every lease carries a monotonically increasing token that must accompany the backend write. This prevents the classic failure: holder pauses, lease expires, a new holder acquires, and the stale holder wakes up and writes anyway. Without fencing, the lock is decorative.
Renewal with a ceiling. LLM reasoning cycles can outlast a lease. Holders heartbeat-renew while a step runs, bounded by a hard maximum so a stuck agent cannot hold forever. Expiry mid-step aborts the step, runs its compensation, and resyncs.
Two-tier arbitration. The backend lease is authoritative exclusivity. The local OTP ResourceServer is cheap first-line arbitration that stops StewardHQ's own agents from even requesting conflicting leases.
3.3 await_step — Structured, Cancellable Plans
A plan is a graph of awaitable steps (Reactor model):

Steps declare run, compensate (retryable failure), and undo (rollback of a completed step because a later one failed).
Cancellation is structured: every in-flight step receives the cancel signal, awaits its compensation, then drops its borrows.
No capability outlives its plan. Sub-agents are supervised tasks scoped to the plan; orphans are impossible. This scoped-lifetime invariant is enforced by the BEAM, not by convention. 4. Four Guarantees, Four Mechanisms
The guarantees are deliberately kept as separable mechanisms — each protects against a different adversary.

Guarantee Mechanism Protects agents from
Isolation Borrow checker (shared/exclusive borrows via OTP ResourceServers) Each other
Consistency Version fencing + freshness policy The outside world
Atomicity Reactor sagas with undo/compensate Partial failure
Legibility Structured errors + reversibility taxonomy Opaque failure
4.1 Isolation — The Borrow Checker
Shared borrow (:read): multiple agents read simultaneously; the resource is locked against mutation.
Exclusive borrow (:write): one holder; all other access blocked or queued per policy.
Borrows are process-linked: if the agent task crashes, the BEAM releases the borrow automatically.
Borrows may be plan-scoped where later steps might trigger an earlier step's undo — releasing early would expose intermediate state to other agents. This raises contention; the DSL tunes the tradeoff per resource.
The Witness Pattern — making the borrow checker unbypassable. A borrow checker that can be sidestepped is advisory, not safety. Every Ash action generated by the DSL therefore requires a borrow_token in its changeset context; the Spark compiler injects this requirement automatically. A call without a valid witness fails with {:error, :unborrowed_access} — including direct Ash calls from application code that never went through the gateway. There is no opt-out path at the resource layer; this is the Rust spirit applied faithfully: safety you cannot forget to use.

Deadlock policy. For multi-resource plans, the Plan Validator sorts all requested borrows canonically (resource_type:id) and acquisition follows that global order, preventing circular waits — a static check, in the compile-time spirit. This only works when the full plan is known upfront. In transactional session mode, where agents borrow incrementally step-by-step, ordering cannot be pre-computed; v1 handles this with acquisition timeouts plus a restriction to one exclusive borrow per session (crude but shippable for the billing wedge). Wound-wait arbitration is the designed-for v2 upgrade.

4.2 Consistency — Drift as a First-Class State
The legacy API is the source of truth, and it has writers StewardHQ does not control. Drift cannot be prevented — only detected and bounded. The honest guarantee is:

No agent action executes against state older than a declared freshness bound, or different from what the agent observed.

Mechanisms, in order of strength:

Version fencing. Shadow resources store a version token (ETag / updated_at). Writes are conditional (If-Match); rejection means drift — abort, resync, surface {:error, :stale_resource, remote_state}.
Verify-on-borrow. Exclusive borrows optionally trigger a fresh read before granting. Shadow state is a cache plus policy layer, never truth.
Change ingestion. Webhooks/CDC/polling keep shadows warm — a freshness optimization only, never a correctness mechanism (delivery is lossy and unordered).
Honest state modeling. Shadow state is synced | stale(age) | conflicted, and the DSL expresses freshness policy per capability: reads may tolerate staleness; a payment cannot.
Idempotency keys — the phantom-payment defense. The nightmare case: the gateway calls POST /pay, the backend returns 500, but the payment actually processed. Retrying creates a double payment; failing the saga records a payment that "never happened." The primary defense is an idempotency key per plan step, sent with every mutating call where the backend supports it — retries become safe by construction and phantom writes impossible rather than merely discoverable. Idempotency support is declared per backend in the DSL (see §6). Where the backend has no idempotency semantics, the fallback is a deep-sync repair step: a specialized Reactor step that polls the backend's read endpoint to determine what actually happened before the saga is allowed to fail or proceed.

Repair loop: if a backend call succeeds but reconciliation fails, the gateway itself is the drifted party while holding a lock. It must re-fetch until consistent before releasing the borrow, or it poisons the next borrower.

Implementation note: fencing lives entirely inside the Ash resource lifecycle — an Ash preparation fetches the version token; an Ash change (Steward.Changes.EnforceFencing) attaches the conditional check (If-Match or equivalent) to the outgoing call and blocks the write if no token is present in context.

4.3 Atomicity — Sagas with Compensation
Plans execute as Reactor graphs, making a multi-step plan roughly transactional: it either lands or unwinds.

Crash-safety composes: process dies → BEAM releases borrows → Reactor runs undos.
Compensations fail too. A persistent retry queue with dead-letter escalation to humans is required — which implies durable saga state (Ash persistence), not just in-memory GenServers.
Capabilities as Reactor inputs. The own primitive moves a capability into its step; success consumes it (linear semantics). On failure, disposition depends on the error type, not on whether a compensation exists: :stale_resource → the capability survives, resync and retry; :invalid_transition → the capability is genuinely useless in this world-state, drop it, forcing a fresh borrow and re-observation. Capability disposition is a function of the structured error taxonomy (§4.4).
4.4 Legibility — The Reversibility Taxonomy
Not every action can be undone. The DSL distinguishes:

undoable — a true inverse exists.
compensatable — a semantic apology, not a reversal (a refund is not an un-payment: fees, ledger entries, and notifications already fired).
irreversible — no recourse (a sent email).
The plan validator enforces a static ordering rule: irreversible steps go last. A plan that schedules an irreversible payment before a fallible step is rejected before execution — the compliance-firewall pitch in one screenshot.

Failures are structured, never bare 403s:

{:error, :borrow_conflict, owner_pid}
{:error, :invalid_transition, current_state}
{:error, :capability_expired}
{:error, :capability_moved}
{:error, :unborrowed_access}
{:error, :unfenced_write}
{:error, :lease_expired}
{:error, :stale_resource, remote_state}
{:error, :irreversible_before_fallible, step_id}
Structured errors let agents recover autonomously: they explain why, not just no.

(v2.3 addendum, Phase 2: :unfenced_write covers a mutating call reaching the backend boundary with
no lease/fencing token in context — the write-side analogue of :unborrowed_access. :lease_expired
covers a §3.2 lease whose TTL or hard renewal ceiling has passed; it is distinct from
:capability_expired, which applies to §3.1 capability tokens.)

5. System Architecture
   [Agent] --(Plan)--> [StewardHQ Gateway (Elixir/Ash)] --(Fenced, leased action)--> [Legacy API]
   |
   [Resource Safety Engine]
   |-- Borrow Checker (OTP ResourceServers) → Isolation
   |-- Version Fencing / Freshness (Ash shadows) → Consistency
   |-- Saga Executor (Reactor) → Atomicity
   |-- Plan Validator + DSL Laws (Spark) → Legibility
   Control plane: Spark DSL defines the laws; compiled into a Resource Safety Graph.
   Data plane: high-concurrency Elixir proxy intercepting agent plans, validating against the graph, executing via leases and fencing.
   Shadow resources: Ash resources mirroring external entities, carrying state, version, freshness, ownership, and policy metadata.
6. The Spark DSL
   defmodule MyApp.StewardshipLaws do
   use Steward.DSL

resource :invoice do
ownership :account_id

    capability :read, mode: :shared
    capability :pay,
      consumption: :linear,
      lifetime: :plan,
      requires_freshness: {:max_age, 30_000},
      reversibility: :compensatable,
      undo: :refund,
      compensate: :retry_with_backoff

    state_machine do
      state :draft, initial?: true
      state :approved
      state :paid

      transition :approve, from: :draft, to: :approved
      transition :pay, from: :approved, to: :paid
    end

    invariant :no_overpay do
      amount_paid <= total_amount
    end

    # Which lock tier the backend supports (fallback ladder)
    locking :conditional_write   # :native_lease | :conditional_write | :serialized

    # Whether the backend accepts idempotency keys on mutations
    idempotency :header, key: "Idempotency-Key"   # :header | :body_field | :none

end
end
Where idempotency :none is declared, mutating steps automatically gain a deep-sync repair step (§4.2) as their failure handler.

The locking declaration encodes the fallback ladder for legacy backends: native lease → conditional writes (version fencing) → single-writer serialization through one GenServer per resource, with the BEAM itself as the lock.

7. Execution Flow
   Plan submission. Agent submits a plan graph: [{action: :read, id: 1}, {action: :pay, id: 1}].
   Static analysis. The Plan Validator simulates the plan against the Safety Graph: valid transitions, capability availability, freshness requirements, and the irreversible-last ordering rule.
   Borrow + lease acquisition. Exclusive borrow requested locally; lease acquired from the backend's lock tier with a fencing token and TTL. Conflicts queue or reject per policy.
   Fenced execution. Each step runs with heartbeat lease renewal; backend writes carry the fencing token and version condition.
   Reconciliation. Backend response verified; shadow state updated. On failure, the repair loop re-fetches until consistent before any release.
   Completion or unwind. On success, borrows release and linear capabilities are consumed. On failure, Reactor runs compensations/undos in reverse, then releases.
8. Implementation Roadmap
   v1 scope — the wedge. One vertical (billing/invoicing), where race conditions have dollar costs. Hardcoded choices: GenServer locks, Ash persistence, a single agent plan protocol. No premature abstraction.

Killer demo: "StewardHQ rejected this plan — an irreversible payment was scheduled before a fallible step."

Adoption wedge — StewardHQ as an MCP server. Rather than requiring agents to adopt the plan protocol, StewardHQ can expose itself as an MCP server of safe tools: instead of a naked pay_invoice tool, each MCP tool call is auto-wrapped as a single-step plan — witness required, lease acquired, fencing applied, structured error returned on failure. Agents get the safety runtime with zero framework changes; full multi-step plans become the graduation path. This may be the easier v1 entry point and should ship alongside (or before) the plan API.

Build order: the OTP Lock Manager comes first — the DSL is only meaningful once there is physics underneath it to compile against.

Phase 1 — Core Kernel
Steward.Registry tracking active borrows and capability tokens (including moves).
Steward.ResourceServer GenServer per resource: local lock arbitration, borrow queueing.
borrow(resource*id, mode, fun) with process-linked auto-release.
Phase 2 — Leases, Fencing & Idempotency
Lease lifecycle: acquire / renew (heartbeat) / release / expire, with fencing tokens.
Version fencing on shadow resources (Steward.Changes.EnforceFencing); {:error, :stale_resource, *} path and resync.
Idempotency-key injection per step; deep-sync repair step for idempotency :none backends.
Repair loop for post-write reconciliation failures.
Phase 3 — DSL & Plan Validation
Steward.Resource Spark extension for Ash; compile DSL → Resource Safety Graph.
Witness enforcement: compiler injects the borrow_token requirement into every generated action.
Plan Validator: state-machine simulation, freshness checks, reversibility ordering, canonical borrow-order sorting.
Phase 4 — Saga Execution
Reactor integration: run / compensate / undo per step; plan-scoped borrows; capability disposition by error type.
Durable saga state in Ash; persistent retry queue; dead-letter escalation to humans.
Phase 5 — Capability Movement & MCP Facade
spawn_agent(name, moves: [caps]) — supervised, plan-scoped sub-agent tasks.
Enforcement of the scoped-lifetime invariant: no capability outlives its plan.
MCP server facade: each tool call wrapped as a witnessed, leased, fenced single-step plan.
Designed-for but deferred: wound-wait deadlock arbitration for session mode, webhook/CDC ingestion, full DSL surface, provider behaviours (§9).

9. Extensibility Strategy (v2+)
   Following the Rust/Tokio split: StewardHQ owns the language; runtimes are swappable behaviours. Extraction happens only after v1's concrete implementation proves where the real seams are.

Seam Behaviour Example providers
Lock/lease providers Steward.LeaseProvider Postgres advisory locks, Redis, Zookeeper, native API leases, dev GenServer
Agent runtimes Plan submission protocol LangGraph, Claude SDK wrappers, homegrown OTP agents
Persistence Durable saga state Ash/Postgres default; pluggable event stores
API adapters Capability + locking declarations per backend Stripe, SAP, Salesforce — community "device drivers"
This split also defines the moat and a clean open-core line: the Resource Safety Engine (borrow rules, linearity, plan validation, reversibility ordering) is the open language; enterprise providers (audit, compliance backends) are the business.

10. Strategic Value
    For enterprises: a steward for your resources in the age of AI — agents never own your invoices, data, or money; they are granted bounded custody, statically checked and dynamically fenced before anything moves.
    For developers: turn any REST API into a type-safe agentic toolset with zero backend changes.
    For agents: structured, legible failure and a transactional plan primitive — "this either lands or unwinds" — enabling genuine autonomous recovery.
    Naming note: StewardHQ is the product and company name; Steward is the Elixir code namespace. The framing deliberately centers the resource, not the agent: the danger being managed is agents mishandling the enterprise's property, and the steward is the entity trusted to prevent that.
