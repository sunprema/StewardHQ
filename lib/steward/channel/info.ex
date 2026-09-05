defmodule Steward.Channel.Info do
  @moduledoc """
  Introspection for the `Steward.Channel` Spark DSL extension
  (docs/tech_spec.md §3.4, §8 Phase 5).
  """

  use Spark.InfoGenerator, extension: Steward.Channel.Dsl, sections: [:channels]

  alias Steward.Channel.{Channel, Message}

  @doc "The `channel` entity named `name`, or `nil`."
  @spec channel(module() | Spark.Dsl.t(), atom()) :: Channel.t() | nil
  def channel(protocol, name) do
    Enum.find(channels(protocol), &(&1.name == name))
  end

  @doc "The `channel` entity named `name`. Raises if `protocol` declares no such channel."
  @spec channel!(module() | Spark.Dsl.t(), atom()) :: Channel.t()
  def channel!(protocol, name) do
    channel(protocol, name) ||
      raise ArgumentError, "no channel #{inspect(name)} declared on #{inspect(protocol)}"
  end

  @doc "All `message` entities declared on `channel_name`."
  @spec messages(module() | Spark.Dsl.t(), atom()) :: [Message.t()]
  def messages(protocol, channel_name) do
    case channel(protocol, channel_name) do
      nil -> []
      channel -> channel.messages
    end
  end

  @doc "The `message` entity named `message_name` on `channel_name`, or `nil`."
  @spec message(module() | Spark.Dsl.t(), atom(), atom()) :: Message.t() | nil
  def message(protocol, channel_name, message_name) do
    Enum.find(messages(protocol, channel_name), &(&1.name == message_name))
  end
end
