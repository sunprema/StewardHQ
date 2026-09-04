defmodule Steward do
  @moduledoc """
  Public stewardship API (docs/tech_spec.md §3, §4.1, §8 Phase 1).

  `Steward.ResourceServer` implements the borrow checker; this module is
  the thin public-facing entry point, named per CLAUDE.md's stewardship
  vocabulary convention (`borrow/3`, not "lock"/"unlock").
  """

  @doc "See `Steward.ResourceServer.borrow/3`."
  defdelegate borrow(resource_id, mode, fun), to: Steward.ResourceServer
end
