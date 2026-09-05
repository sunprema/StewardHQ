defmodule Steward.Channel.Dsl do
  @moduledoc """
  The `Spark.Dsl.Extension` compiling `channel` blocks into a declaration
  for `Steward.ChannelServer`'s bounded, GenServer-backed mailboxes
  (docs/tech_spec.md §3.4, §8 Phase 5).

  Not consumed directly — `Steward.Channel` wraps this as a
  `Spark.Dsl` (same split `Reactor`/`Reactor.Dsl` use), so a protocol
  module declares channels with `use Steward.Channel`.
  """

  alias Steward.Channel.{Channel, Message}

  @message %Spark.Dsl.Entity{
    name: :message,
    args: [:name],
    identifier: :name,
    target: Message,
    describe: "A named message type this channel carries (spec §3.4).",
    schema: [
      name: [type: :atom, required: true, doc: "The message's name."],
      schema: [type: :module, doc: "The module describing this message's payload shape."]
    ],
    examples: ["message :charge_request, schema: Billing.ChargeRequest"]
  }

  @channel %Spark.Dsl.Entity{
    name: :channel,
    args: [:name],
    identifier: :name,
    target: Channel,
    entities: [messages: [@message]],
    describe: "A bounded, typed transport for capability/task movement (spec §3.4).",
    schema: [
      name: [type: :atom, required: true, doc: "The channel's name."],
      capacity: [
        type: :pos_integer,
        default: 100,
        doc: "Maximum number of undelivered messages this channel holds."
      ],
      overflow: [
        type: {:in, [:block, :reject]},
        default: :reject,
        doc: "Policy when a send would exceed capacity (spec §3.4)."
      ],
      overflow_timeout: [
        type: :pos_integer,
        doc: "Required when overflow: :block — the max time a send waits for space."
      ],
      allow_delegation: [
        type: {:list, :atom},
        default: [],
        doc: "Capability names this channel is allowed to carry as message payloads."
      ],
      require_intent: [
        type: :boolean,
        default: false,
        doc: "Whether every message must declare an :intent, or fail :intent_required."
      ]
    ],
    examples: [
      """
      channel :payment_processing do
        capacity 50
        overflow :block
        overflow_timeout 5_000
        message :charge_request, schema: Billing.ChargeRequest
        allow_delegation [:read_customer, :write_invoice]
        require_intent true
      end
      """
    ]
  }

  @channels %Spark.Dsl.Section{
    name: :channels,
    describe: "Declares the typed, bounded channels this protocol module carries (spec §3.4).",
    entities: [@channel],
    examples: [
      """
      channels do
        channel :payment_processing do
          capacity 50
          message :charge_request
        end
      end
      """
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@channels],
    verifiers: [Steward.Channel.Verifiers.VerifyOverflow]
end
