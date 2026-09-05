defmodule Steward.Channel.Verifiers.VerifyOverflow do
  @moduledoc """
  Enforces docs/tech_spec.md §3.4's "Overflow is bounded. `overflow
  :block` always carries a timeout (no infinite `receive`)": a compile
  error, not a runtime surprise, if a channel declares `overflow :block`
  without an `overflow_timeout`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError
  alias Steward.Channel.Info

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Info.channels()
    |> Enum.filter(&(&1.overflow == :block and is_nil(&1.overflow_timeout)))
    |> case do
      [] ->
        :ok

      [channel | _rest] ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:channels, channel.name],
           message:
             "channel #{inspect(channel.name)} declares `overflow :block` but no `overflow_timeout` — blocking overflow must always be bounded."
         )}
    end
  end
end
