defmodule Steward.Channel do
  @moduledoc """
  Spark DSL for declaring typed, bounded transports for capability/task
  movement across an agent process boundary (docs/tech_spec.md §3.4
  "channel — Typed Transport for Capability Movement", §8 Phase 5).

  Not a fourth primitive alongside `own`/`lease(ttl)`/`await_step` — a
  channel is the concrete transport those run over whenever a capability
  or task crosses a process boundary (a supervisor delegating a
  sub-task, `Steward.SpawnAgent.spawn_agent/2`'s degenerate one-message
  case, or two peer agents coordinating a hand-off).

  Wraps `Steward.Channel.Dsl` (the actual `Spark.Dsl.Extension`) as a
  `Spark.Dsl`, the same split `Reactor`/`Reactor.Dsl` use — this is what
  makes `use Steward.Channel` below work directly, rather than requiring
  callers to thread `extensions: [Steward.Channel.Dsl]]` through some
  other framework the way `Steward.Resource` rides on `Ash.Resource`.

  ## Usage

      defmodule MyApp.Protocols.Billing do
        use Steward.Channel

        channels do
          channel :payment_processing do
            capacity 50
            overflow :block
            overflow_timeout 5_000

            message :charge_request, schema: Billing.ChargeRequest
            message :charge_completed, schema: Billing.ChargeResult

            allow_delegation [:read_customer, :write_invoice]
            require_intent true
          end
        end
      end

  ## Deviations from the spec's illustrative syntax

  The spec's own example writes `channel :payment_processing do ... end`
  directly at module level (no wrapping section) and `overflow :block,
  timeout: 5_000` as one call. This extension instead wraps `channel`
  blocks in a `channels do ... end` section — consistent with how
  `Steward.Resource` wraps its DSL in `steward do ... end` — and splits
  overflow into two flat options (`overflow`, `overflow_timeout`) rather
  than one call carrying a keyword argument. Per CLAUDE.md ("If code and
  spec disagree, flag it"): this is a deliberate DSL-surface
  simplification, not a semantic one — every guarantee the spec text
  describes (bounded capacity, `:block` always timing out, `:reject`
  surfacing `{:error, :channel_full}` immediately, `allow_delegation`
  naming only pre-declared capabilities) is enforced exactly as written,
  by `Steward.Channel.Verifiers.VerifyOverflow` and
  `Steward.ChannelServer` at runtime.

  A message never invents authority: `allow_delegation` may only name
  capabilities the channel's declaring module chooses to hand over — this
  extension has no way to check those names against a `Steward.Resource`
  capability block (a channel module and a resource module are usually
  different modules entirely), so that cross-check is the caller's
  responsibility when constructing the capability to send, the same way
  `Steward.Resource.Info.capability/2` is any other caller's
  responsibility to check before granting one.
  """

  use Spark.Dsl, default_extensions: [extensions: [Steward.Channel.Dsl]]
end
