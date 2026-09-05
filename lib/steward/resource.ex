defmodule Steward.Resource do
  @moduledoc """
  Spark DSL extension compiling an Ash resource's stewardship laws into a
  Resource Safety Graph (docs/tech_spec.md §6, §8 Phase 3; CLAUDE.md
  architecture map: "Steward.Resource — Spark DSL extension; compiles
  laws → Resource Safety Graph").

  ## Usage

      defmodule MyApp.Invoice do
        use Ash.Resource, extensions: [Steward.Resource]

        steward do
          ownership :account_id

          capability :read, mode: :shared
          capability :pay,
            mode: :exclusive,
            consumption: :linear,
            reversibility: :compensatable,
            undo: :refund,
            compensate: :retry_with_backoff,
            requires_freshness: {:max_age, 30_000}

          state_machine do
            state :draft, initial?: true
            state :approved
            state :paid

            transition :approve, from: :draft, to: :approved
            transition :pay, from: :approved, to: :paid
          end

          invariant :no_overpay, expr(amount_paid <= total_amount)

          locking :conditional_write
          idempotency :header, key: "Idempotency-Key"
        end
      end

  Every action compiled by this extension carries the witness
  requirement from CLAUDE.md invariant 1 ("No unwitnessed access") —
  see `Steward.Resource.Transformers.RequireWitness`. There is no
  opt-out at the resource layer; a resource cannot "forget" to require a
  `borrow_token`.

  `Steward.Resource.Info` introspects the compiled DSL;
  `Steward.Resource.SafetyGraph.build/1` assembles it into the struct
  `Steward.PlanValidator` performs static analysis against (spec §7
  "Static analysis").
  """

  alias Steward.Resource.{Capability, IdempotencyPolicy, Invariant, State, Transition}

  @capability %Spark.Dsl.Entity{
    name: :capability,
    args: [:name],
    identifier: :name,
    target: Capability,
    describe: "A right an agent can be granted over this resource (spec §3.1, §6).",
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The capability's name; matches the Ash action it governs."
      ],
      mode: [
        type: {:in, [:shared, :exclusive]},
        default: :exclusive,
        doc: "Borrow mode required to exercise this capability (spec §4.1)."
      ],
      consumption: [
        type: {:in, [:linear, :reusable]},
        default: :reusable,
        doc: "Whether exercising this capability consumes it (spec §3.1)."
      ],
      lifetime: [
        type: {:in, [:plan, :step]},
        default: :plan,
        doc: "How long a granted instance of this capability may live (spec §3.1/§3.3)."
      ],
      requires_freshness: [
        type: {:or, [{:tagged_tuple, :max_age, :pos_integer}, {:in, [:any]}]},
        default: :any,
        doc: "Freshness policy the Plan Validator checks plan steps against (spec §4.2)."
      ],
      reversibility: [
        type: {:in, [:undoable, :compensatable, :irreversible]},
        default: :undoable,
        doc: "Reversibility class used by the Plan Validator's ordering rule (spec §4.4)."
      ],
      undo: [
        type: :atom,
        doc: "Action name that reverses this capability's effect, when :undoable."
      ],
      compensate: [
        type: :atom,
        doc:
          "Action/strategy name compensating for this capability's effect, when :compensatable."
      ]
    ],
    examples: [
      "capability :read, mode: :shared",
      "capability :pay, consumption: :linear, reversibility: :compensatable"
    ]
  }

  @invariant %Spark.Dsl.Entity{
    name: :invariant,
    args: [:name, :expr],
    identifier: :name,
    target: Invariant,
    imports: [Ash.Expr],
    describe: "A named predicate that must hold for this resource (spec §6).",
    schema: [
      name: [type: :atom, required: true, doc: "A unique name for this invariant."],
      expr: [type: :any, required: true, doc: "An `Ash.Expr` predicate, via `expr/1`."]
    ],
    examples: ["invariant :no_overpay, expr(amount_paid <= total_amount)"]
  }

  @idempotency %Spark.Dsl.Entity{
    name: :idempotency,
    args: [:mode],
    target: IdempotencyPolicy,
    describe: "Whether/how the backend accepts idempotency keys on mutations (spec §4.2, §6).",
    schema: [
      mode: [
        type: {:in, [:header, :body_field, :none]},
        required: true,
        doc: "See `Steward.Idempotency.mode/0`."
      ],
      key: [type: :string, doc: "Header or body field name carrying the idempotency key."]
    ],
    examples: ["idempotency :header, key: \"Idempotency-Key\"", "idempotency :none"]
  }

  @state %Spark.Dsl.Entity{
    name: :state,
    args: [:name],
    identifier: :name,
    target: State,
    schema: [
      name: [type: :atom, required: true],
      initial?: [type: :boolean, default: false, doc: "Whether this is the initial state."]
    ],
    examples: ["state :draft, initial?: true"]
  }

  @transition %Spark.Dsl.Entity{
    name: :transition,
    args: [:name],
    identifier: :name,
    target: Transition,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The capability/action name that performs this transition."
      ],
      from: [type: :atom, required: true],
      to: [type: :atom, required: true]
    ],
    examples: ["transition :approve, from: :draft, to: :approved"]
  }

  @state_machine %Spark.Dsl.Section{
    name: :state_machine,
    describe: "The valid states of this resource and the transitions between them (spec §6).",
    entities: [@state, @transition],
    examples: [
      """
      state_machine do
        state :draft, initial?: true
        state :approved

        transition :approve, from: :draft, to: :approved
      end
      """
    ]
  }

  @steward %Spark.Dsl.Section{
    name: :steward,
    describe: """
    Declares the stewardship laws for this resource: ownership, capabilities,
    its state machine, locking tier, and idempotency support
    (docs/tech_spec.md §6).
    """,
    schema: [
      ownership: [
        type: :atom,
        required: true,
        doc: "The attribute identifying who this resource belongs to."
      ],
      locking: [
        type: {:in, [:native_lease, :conditional_write, :serialized]},
        default: :serialized,
        doc: "Which lock tier the backend supports, per the fallback ladder (spec §6)."
      ]
    ],
    entities: [@capability, @invariant, @idempotency],
    sections: [@state_machine],
    singleton_entity_keys: [:idempotency],
    examples: [
      """
      steward do
        ownership :account_id
        capability :read, mode: :shared
        locking :conditional_write
      end
      """
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@steward],
    transformers: [Steward.Resource.Transformers.RequireWitness]
end
