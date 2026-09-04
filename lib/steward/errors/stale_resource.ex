defmodule Steward.Errors.StaleResource do
  @moduledoc """
  Raised/added when `Steward.Backend.write/4` rejects a write because the
  expected version no longer matches the backend's current state
  (docs/tech_spec.md §4.2, §4.4 `{:error, :stale_resource, remote_state}`).
  """

  use Splode.Error, fields: [:resource, :remote_state], class: :invalid

  def message(error) do
    "Attempted to write stale resource #{inspect(error.resource)}: backend state has moved on (#{inspect(error.remote_state)})"
  end
end
