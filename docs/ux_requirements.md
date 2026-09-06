# StewardHQ Console — UX Requirements

Version 0.1, 2026-09-05. Audience: design team, for producing mockup screens.
Companion to `docs/agent_interaction_ux.md` (engineering view of the same screens).

## 1. What this product is, in one paragraph

StewardHQ sits between AI agents and a company's business systems (invoices, orders,
payments). Agents never own those records. They are granted temporary, bounded stewardship:
a **borrow** to look at or change a record, a **lease** that expires, and a **capability**
that can be used exactly once. The runtime enforces this. If an agent misbehaves or crashes,
the runtime takes the record back automatically. The console we are designing is the window
into that runtime: it shows what agents did, what they hold right now, and proof that the
safety rules held.

Guiding phrase: **agents propose, the steward disposes.** The console is on the steward's
side. It observes; it never lets a human bypass the rules from the UI.

## 2. Who uses it

| Persona | Core question | Frequency |
| --- | --- | --- |
| **Operator** (runs the platform) | "Is anything stuck or expiring? Who holds what right now?" | Continuous, glanceable |
| **Agent developer** (builds agents) | "What did my agent do, step by step, and why did that step fail?" | Many times a day, investigative |
| **Reviewer / auditor** (trusts or approves the system) | "Show me that nothing touched a record without permission and every one-shot capability was used once." | Occasional, deep |

The operator needs density and live updates. The developer needs drill-down and error
detail. The reviewer needs a clear narrative and evidence. Mockups should show which
persona each screen primarily serves.

## 3. Vocabulary the UI must use

Use these words in labels, headings and empty states. Do not use "lock", "unlock",
"permission" or "user" for these concepts.

| Term | Meaning for the UI | Notes |
| --- | --- | --- |
| **Resource** | A business record under stewardship (an invoice, an order). Identified by a resource id. | Ids are opaque strings, often long. |
| **Borrow** | An agent's temporary hold on a resource. **Shared** (read, many at once) or **exclusive** (write, one at a time). | Others wait in a **queue**. |
| **Lease** | The time limit on a borrow. Has a fencing token (a counter) and an expiry. | Expired lease means writes are refused. |
| **Capability** | A single-use right to perform one action on one resource. States: active, moved, consumed, expired, dropped. | "Linear": used once, then gone. |
| **Move** | Handing a capability from one agent to another. The sender loses it. | Reuse after a move is an error. |
| **Plan** | An ordered list of steps an agent proposes to run. | Validated before execution. |
| **Saga** | One execution of a plan. States: running, completed, failed, dead-letter. | Retries are counted. |
| **Step** | One action inside a saga. States: pending, succeeded, failed, undone. | Has a disposition: consumed, survived, dropped. |
| **Disposition** | What happened to the step's capability after the outcome. | Key audit signal. |
| **Shadow record** | The runtime's cached copy of a backend record. Sync state: synced, stale (with age), conflicted. | Cache, never truth. |
| **Repair loop** | Re-fetching a backend record until the cache agrees with it. | Runs before a borrow is released. |
| **Agent / sub-agent** | A running process acting on behalf of a plan. Sub-agents are spawned by a parent and die with its plan. | Show a name when known; a process id otherwise. |
| **Channel** | A bounded mailbox through which a parent agent hands work and capabilities to a sub-agent. | Has capacity and an overflow policy. |

Error reasons that appear throughout the UI (these are fixed; do not reword them, but do
provide a plain-language subtitle):

| Error | Plain-language subtitle |
| --- | --- |
| `unborrowed_access` | Tried to touch a resource without borrowing it first |
| `unfenced_write` | Tried to write without a lease token |
| `lease_expired` | Held the resource too long; the lease ran out |
| `stale_resource` | The backend changed underneath the agent; needs a resync |
| `invalid_transition` | Asked for a state change the resource does not allow |
| `capability_moved` | Tried to reuse a capability already handed to another agent |
| `irreversible_before_fallible` | Plan puts an irreversible step before one that can fail |

## 4. Design principles

1. **Read-only by construction.** No screen offers release, move, retry or edit actions.
   The only mutation-like control is "re-run validation" on the plan screen, which changes
   nothing. Mockups must not include destructive buttons "for later".
2. **Two kinds of state, visibly different.** History (sagas, steps) is durable and survives
   restarts. Live state (borrows, leases, capabilities, agents, channels) is in memory and
   vanishes on restart. Live screens must say "no live state" and when the runtime started,
   never show a blank grid that could be mistaken for "nothing ever happened".
3. **Evidence over summary.** Every count links to the rows behind it. Every status has a
   timestamp. Every error shows its reason and the step that produced it.
4. **Time is a first-class axis.** Leases expire; queues age; shadow records go stale.
   Relative time ("expires in 12 s", "stale for 4 m") with absolute time on hover.
5. **Opaque identifiers need help.** Resource ids, borrow refs, capability refs and saga ids
   are long and meaningless to humans. Truncate consistently, always offer copy, and show
   the friendly name (resource type, agent name) first.
6. **Live, but calm.** Screens update without a refresh. Changes should be noticeable but
   not flashing. A single "live / paused / disconnected" indicator per screen.
7. **Status colour is semantic and consistent.** One palette meaning across all screens:
   healthy / in progress / waiting / warning (expiring, stale) / error / terminal-dead
   (dead-letter, dropped). Never rely on colour alone; pair with an icon or label.

## 5. Information architecture

```
Console
├── Overview                      (operator landing)
├── Activity
│   └── Sagas (timeline)  →  Saga detail  →  Step detail
├── Live
│   ├── Borrow board      →  Resource detail
│   ├── Capabilities      →  Capability detail
│   └── Agents            →  Agent detail
├── Consistency
│   └── Shadow records    →  Record detail (with repair history)
├── Errors
└── Tools
    └── Plan validator
```

Global elements on every screen: search by resource id / saga id / agent name, the live
indicator, and an environment badge (dev / staging / prod). Deep links between screens are
required wherever an id appears: a resource id on the borrow board opens that resource's
recent sagas; an agent on the timeline opens the agent tree; an error on a step opens the
errors screen filtered to that reason.

## 6. Screen requirements

Each screen lists: primary persona, the questions it answers, required content, required
states, interactions, and explicit non-goals. Data-availability notes tell the designer
whether the content exists today or is planned.

### 6.1 Overview

Persona: operator. Glanceable, fits on one screen without scrolling at laptop size.

Answers: Is the runtime healthy right now? Is anything about to go wrong?

Content:
- Live tiles: active borrows (shared / exclusive split), queued waiters, active
  capabilities, running sagas, live agents.
- Attention list: leases expiring within a threshold, queues older than a threshold,
  shadow records that are conflicted, sagas in dead-letter. Each row deep-links.
- Recent activity strip: last N saga completions and failures.
- Error mini-chart: errors by reason over the last hour.

States: healthy (empty attention list is a positive, say so), attention needed, runtime
just restarted (live tiles zero with an explanation), disconnected.

Non-goals: no configuration, no charts beyond the error mini-chart.

### 6.2 Sagas (interaction timeline)

Persona: agent developer. This is the most-used investigative screen.

Answers: What did agents do? Which runs failed, and where?

Content, list level:
- One row per saga: id (truncated), status, initiating agent or tool name, resource types
  touched, step count with succeeded / failed / undone breakdown, attempts, started, duration.
- Filters: status, resource type, resource id, agent, time range, "has errors".
- Sort by start time (default, newest first) and duration.

Content, saga detail:
- Header: status, attempts, timestamps, the plan as originally submitted (collapsible).
- Step list in execution order. Each step: step id, resource type and id, action, status,
  disposition, duration. Failed steps show the error reason and subtitle inline.
- If steps were undone, show the undo order distinctly (compensation runs in reverse).
- Link to the agent tree for the agent that ran it, and to each resource's borrow history.

Content, step detail:
- Full result or error payload (structured, not raw JSON by default; raw available).
- The capability used, its disposition, and why (rule: stale_resource survives for retry;
  invalid_transition drops).
- Borrow and lease at time of execution (mode, fencing token).

States: empty (no sagas yet, with a pointer to the cookbook), loading, filtered-to-nothing,
running saga (steps still appearing), failed, dead-letter (say what dead-letter means and
that retries have stopped).

Interactions: expand/collapse steps, copy ids, jump to related screens. No retry button.

Data notes: everything at list and saga level exists today. Agent name on a saga is
planned; until then show the tool name.

### 6.3 Borrow board (live)

Persona: operator. Dense, scannable, updates in place.

Answers: Who holds what right now? Is anyone waiting? Is anything about to expire?

Content:
- One row per resource with any live state: resource type and id, current holders
  (shared count or the single exclusive holder), lease token and expiry countdown, queue
  depth with the oldest waiter's age.
- Expand a row to see each holder and each waiter: agent name or process id, mode
  requested, held-since or waiting-since.
- Filters: resource type, mode, "has queue", "expiring soon".
- Sort: expiry (soonest first), queue age, resource type.

States: no live state (with runtime start time), healthy, contention (queues present),
expiring, disconnected.

Interactions: expand rows, copy ids, deep-link to resource sagas and to the holder in the
agent tree. Pause live updates to read.

Non-goals: no release action, ever.

Data notes: holders and queue depth exist today; holder identity and per-waiter detail are
planned. Design for the full version.

### 6.4 Capabilities (ledger)

Persona: reviewer, then developer.

Answers: Which capabilities exist, who holds them, and was each one used exactly once?

Content:
- One row per capability: ref (truncated), action, resource type and id, holder (agent),
  status (active / moved / consumed / expired / dropped), issued-at, the saga it belongs
  to.
- Capability detail: a vertical lifecycle. Issued → (moved to X) → consumed / dropped /
  expired, each with a timestamp and the step or event that caused it. A move shows both
  parties. A reuse attempt after a move appears as a rejected event, not a state change.
- Filters: status, resource type, holder, saga.

States: no live capabilities, healthy, and a highlighted "anomaly" state if a capability
appears to have been used twice (should be impossible; the UI must make it loud if it ever
shows).

Non-goals: no move or revoke actions.

Data notes: the runtime tracks all of this; the listing endpoint is planned.

### 6.5 Agents (tree)

Persona: developer and operator.

Answers: Which agents are alive? Who spawned whom? What does each one hold? When one
died, did the runtime take everything back?

Content:
- Tree: parent agent → channel → sub-agent, as many levels as exist. Each node: name or
  process id, alive / exited, uptime, the plan it belongs to.
- Node detail: borrows held, capabilities held, channel mailbox state (queued messages
  against capacity, overflow policy), current saga.
- Exit events: when a node exits, keep it visible briefly, greyed, with a "released:
  N borrows, M capabilities" summary. This is the proof of automatic cleanup.

States: no live agents, single agent, deep tree (design for 3+ levels and 10+ siblings),
recently-exited nodes present.

Interactions: expand/collapse, select a node to see its holdings on the side, deep-link to
its sagas.

Data notes: live processes and channel state exist; the exit summary and persistent agent
names are planned.

### 6.6 Shadow records (drift and reconciliation)

Persona: operator and reviewer.

Answers: Is our cached view of the backend trustworthy? Where did it drift, and did repair
succeed?

Content:
- One row per shadow record: resource type and id, backend status, version, sync state
  (synced / stale with age / conflicted), last synced.
- Record detail: side-by-side of cached values vs last known backend values when
  conflicted; a repair history list (attempt number, time, outcome) for the most recent
  repair loop.
- Filters: sync state, resource type, "repair failed".

States: all synced (positive empty), stale records, conflicted records, repair in progress
(attempts appearing live), repair failed (escalated; say what happens next).

Non-goals: no manual edit or force-sync.

Data notes: record list and sync state exist; repair attempt history is planned.

### 6.7 Errors

Persona: developer.

Answers: What is going wrong most, and which agent or tool causes it?

Content:
- Summary: count per error reason for a selectable time range, with the plain-language
  subtitle beside each reason.
- Breakdown: by tool name and by agent.
- Recent list: time, reason, agent or tool, resource, deep-link to the step.

States: no errors (positive), errors present, filtered.

Non-goals: no alerting configuration.

Data notes: historical errors are available from steps; live counts are planned.

### 6.8 Plan validator (tool)

Persona: developer, and anyone learning the system.

Answers: Would this plan be accepted? If not, which rule did it break and where?

Content:
- Input: paste a plan, or pick a past saga's plan.
- Output: the plan drawn as an ordered step list or graph, each step tagged reversible /
  compensatable / irreversible and fallible / infallible.
- Verdict: accepted, or rejected with the rule and the offending step highlighted in the
  drawing. The "irreversible before fallible" rejection must be visually obvious: point at
  both steps involved.

States: empty input, valid, invalid, malformed input (parse error, distinct from a rule
rejection).

Interactions: edit and re-validate. Nothing is executed from this screen.

Data notes: fully available today.

## 7. Cross-cutting requirements

- **Live indicator.** Every live screen shows connected / paused / disconnected. On
  disconnect, keep the last data visible and greyed with the time it was last fresh.
- **Time display.** Relative by default, absolute on hover, all times in one timezone
  chosen at the top level.
- **Identifiers.** Fixed-width truncated form with copy affordance. Full id in a tooltip.
  Friendly name first where one exists.
- **Status vocabulary.** Use the exact status words from section 3. Provide a consistent
  chip component for saga status, step status, capability status, sync state and borrow
  mode.
- **Colour semantics.** One shared mapping (section 4, principle 7). Must pass contrast
  requirements in light and dark themes and remain distinguishable without colour.
- **Density.** Operator screens (overview, borrow board) are dense tables. Developer screens
  (saga detail, step detail) are more spacious with structured payload views.
- **Responsiveness.** Primary target is desktop. Tablet width should degrade to stacked
  layouts; phone is out of scope for mockups.
- **Accessibility.** Keyboard navigation through tables and trees, screen-reader labels on
  status chips, no information carried by colour alone.
- **Empty and error states** are part of every screen's mockup set, not an afterthought.
- **Environment badge** always visible, since prod exposes no tools by default and dev
  exposes demo resources.

## 8. Out of scope

- Any action that changes runtime state (release, move, retry, edit, force-sync).
- Authorization or role management screens. Stewardship is not authorization.
- Alert configuration, notification routing.
- Configuration of resources, channels or leases.
- Mobile layouts.

## 9. Deliverables requested from design

1. Information architecture and navigation mockup (section 5).
2. Component sheet: status chip, identifier with copy, live indicator, time display,
   error reason with subtitle, tree node, countdown.
3. Mockups for each screen in section 6, each with at least: populated, empty / no live
   state, and one error or attention state.
4. Two flows end to end:
   - Developer: overview → failing saga → failed step → error reason → errors screen.
   - Reviewer: capabilities → one capability's lifecycle → the saga step that consumed it →
     the agent that ran it.
5. Light and dark theme for the overview and saga detail screens.

## 10. Open questions for design

1. Should the borrow board be a table or a resource-centric card grid? Density argues for
   a table; contention visibility argues for cards.
2. How should a moved capability be drawn so that "the sender lost it" is unmistakable?
3. For the agent tree, is a left-to-right tree or a nested list better at 3+ levels with
   many siblings?
4. How long should an exited agent remain visible, and how is that communicated?
5. Is one global time range control acceptable, or do Sagas and Errors need their own?
