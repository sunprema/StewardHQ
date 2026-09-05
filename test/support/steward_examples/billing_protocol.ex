defmodule Steward.Test.Examples.BillingProtocol do
  @moduledoc """
  Test-only `Steward.Channel` protocol exercising the Phase 5 DSL surface
  end to end (docs/tech_spec.md §3.4): bounded capacity with both
  overflow policies, `require_intent`, and `allow_delegation`.
  """

  use Steward.Channel

  channels do
    channel :reject_on_full do
      capacity(1)
      overflow(:reject)
      message :ping
    end

    channel :block_on_full do
      capacity(1)
      overflow(:block)
      overflow_timeout(200)
      message :ping
    end

    channel :requires_intent do
      capacity(10)
      require_intent(true)
      message :ping
    end

    channel :delegates_read_only do
      capacity(10)
      allow_delegation([:read])
      message :handoff
    end
  end
end
