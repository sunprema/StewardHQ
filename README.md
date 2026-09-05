# StewardHQ

StewardHQ is a safety layer you put in front of your business APIs so that AI agents can act on them without being able to break them.

## The problem

Give an LLM agent a `pay_invoice` tool and a `cancel_order` tool, and sooner or later something goes wrong that has nothing to do with the model being "dumb": two agents race to update the same invoice, a network call to the payment provider times out and the agent retries — and now the customer's been charged twice, or a multi-step plan pays an invoice and then fails on step four with no way to undo the payment. These aren't prompting problems. They're the same problems any concurrent system has always had — race conditions, partial failure, stale reads — except now the thing driving the system is non-deterministic and doesn't necessarily notice it broke something.

StewardHQ's answer: don't trust agents with resources, and don't rely on the agent to behave. Enforce the safety at the runtime layer, the same way a type system or a borrow checker enforces correctness whether or not the programmer was careful.

## The core idea

**Agents propose; the steward disposes.** An agent never gets direct access to an invoice, an order, or a payment. It gets *temporary, bounded stewardship* of one — a lease with an expiry, a capability that's consumed the moment it's used, a plan that either completes in full or gets unwound step by step. StewardHQ is the thing standing between the agent and the real API, and it is the only path either of them has to get there.

This is deliberately inspired by Rust's ownership model, applied to business resources instead of memory:

- **One holder at a time.** A resource has exactly one exclusive holder, or several shared readers — never both. Handing off rights *moves* them; it never quietly copies them.
- **Locks are leases, not promises.** Every lock has a time limit and a fencing token. Expiry is normal, not an edge case — and a write that shows up after the lease expired is rejected by the backend itself, not just by convention.
- **Plans are transactional.** A multi-step agent plan either lands completely or unwinds through compensation/undo steps. Nothing is left half-done.

The bet is that this needs to be **structural**, not advisory: an agent (or a careless engineer writing internal code) shouldn't be able to bypass the safety by accident. There is no code path to the real API that skips the borrow check, the lease, or the fencing token.

## What that looks like in practice

- **Borrow checking.** Every action on a protected resource needs a `borrow_token`. No token, no access — including from your own application code. `{:ok, ref} = borrow(:invoice_123, :exclusive, fn -> ... end)` and the borrow is released automatically when the function returns, crashes, or the process holding it dies.
- **Fencing.** Every write to the real backend carries a version check and a fencing token, so a write from a holder whose lease already expired is rejected outright instead of silently corrupting state.
- **Linear capabilities.** A right like "pay this invoice" can be handed from a supervisor agent to a sub-agent, but not to both at once — using it, or moving it again, consumes the original. This is what stops two sub-agents from ever independently exercising the same payment right.
- **Sagas with real rollback.** Plans run as a graph of steps, each with a `run`, a `compensate` (retryable failure), and an `undo` (rollback because a *later* step failed). The plan validator refuses to even schedule a plan that puts an irreversible step (like "send an email") before a step that might still fail.
- **Structured, legible errors.** Failures come back as `{:error, :stale_resource, remote_state}` or `{:error, :capability_moved}` — never a bare exception or a `false` — so an agent (or the person debugging it) can tell *why* something didn't work and what its options are.

If you want the full design rationale and the complete guarantee-by-guarantee breakdown, read [`docs/tech_spec.md`](docs/tech_spec.md) — it's the authoritative spec for this project, and code that disagrees with it is considered a bug in one of the two.

## How it's built

StewardHQ is an Elixir/OTP application built on:

- **[Ash Framework](https://ash-hq.org/)** — resources, actions, and the declarative layer everything else hooks into.
- **[Spark DSL](https://hexdocs.pm/spark)** — the custom `Steward.Resource` and `Steward.Channel` extensions that let you *declare* a resource's safety rules (capabilities, state machine, locking policy) and have them compiled into an enforced "Resource Safety Graph," rather than hoping every call site remembers to check them.
- **[Reactor](https://hexdocs.pm/reactor)** — saga/plan execution, so a multi-step agent plan gets `run`/`compensate`/`undo` semantics for free.
- **Postgres (via AshPostgres)** — durable saga state, so a crashed node doesn't lose track of an in-flight plan.
- Plain OTP underneath all of it — the lock arbitration is a `GenServer` per resource, borrows are tied to process lifetime via `Process.monitor`, and none of the safety guarantees depend on cooperative cleanup.

Everything lives under the `Steward.*` namespace. "StewardHQ" is the product name; `Steward` is the code.

### Architecture, roughly

```
Steward.Registry        — tracks active borrows and capability tokens
Steward.ResourceServer  — one GenServer per resource: lock arbitration, borrow queue
Steward.CapabilityRegistry — linear capability tokens: issue, move, expire
Steward.Channel         — typed, bounded transport for moving capabilities/tasks across process boundaries
Steward.Resource        — the Spark DSL where a resource's safety rules are declared
Steward.PlanValidator   — checks a plan before it's allowed to run (ordering, freshness, deadlock avoidance)
Steward.SagaExecutor    — runs plans as Reactor sagas: run / compensate / undo
Steward.Changes.EnforceFencing — the Ash change that makes an unfenced write impossible to express
```

## Where the project is

This is being built one phase at a time, on purpose — later phases aren't started until the earlier ones have real code to build on top of. Current status:

- ✅ **Phase 1 — Core Kernel**: the borrow checker itself (registry, per-resource lock arbitration, crash-safe borrowing).
- ✅ **Phase 2 — Leases, Fencing & Idempotency**: lease lifecycle, fencing tokens, drift detection and repair.
- ✅ **Phase 3 — DSL & Plan Validation**: the `Steward.Resource` DSL, witness enforcement, and the static plan validator.
- ✅ **Phase 4 — Saga Execution**: Reactor-backed plans with compensation/undo and durable saga state.
- 🟡 **Phase 5 — Capability Movement & Channels**: linear capability moves, the `Steward.Channel` DSL, and channel-backed sub-agent spawning are done and tested. The MCP server facade (exposing StewardHQ's safety runtime as a set of MCP tools) is still to come.

See [`CLAUDE.md`](CLAUDE.md) for the invariants every change has to hold, and the phase-by-phase build order.

## Getting started

You'll need Elixir/OTP and a running Postgres.

```bash
mix setup        # installs deps, sets up the database, builds assets
mix test         # runs the test suite (spins up its own database state)
mix phx.server   # starts the app at http://localhost:4000
```

Useful commands while working on this codebase:

```bash
mix precommit    # compile with warnings-as-errors, drop unused deps, format, run tests — run this before committing
mix credo --strict
mix dialyzer
mix ash.codegen --name describe_your_change   # after changing any Ash resource, to generate migrations
```

## A note on scope

This isn't an authorization system — it doesn't decide *who* is allowed to do something (that's your existing auth/RBAC's job, and this composes with it, not replaces it). It decides what happens *after* something is allowed: how the action is bounded, tracked, and rolled back if it goes wrong. If you're looking for "can this user do X," this isn't that. If you're looking for "an agent was allowed to try X — now make sure it can't corrupt anything while doing it," that's what this is for.
