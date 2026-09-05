defmodule Steward.Resource.Transformers.RequireWitness do
  @moduledoc """
  Injects `Steward.Resource.Validations.RequireWitness` as a global
  validation on every resource using the `Steward.Resource` extension —
  covering create, update, destroy, and generic actions alike
  (docs/tech_spec.md §4.1 "The Spark compiler injects this requirement
  automatically... There is no opt-out path at the resource layer";
  CLAUDE.md invariant 1: "Every Ash action on a stewarded resource
  requires a borrow_token in changeset context").

  Deliberately excludes `:read` (queries have no changeset — invariant 1
  is scoped, consistently in both CLAUDE.md and the spec, to "changeset
  context"). This isn't just literal-mindedness: Ash's own atomic-update
  machinery re-fetches the affected row via an internal, context-less
  read after an atomic write to hydrate the returned struct. Witnessing
  `:read` too would reject that internal re-fetch and break every atomic
  update — a self-inflicted `:unborrowed_access` with no agent involved.

  This is what makes witnessing structural rather than a per-action
  convention an author could forget: it runs once, at compile time, for
  every resource that declares `extensions: [Steward.Resource]`,
  regardless of what `steward do ... end` block that resource writes.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Dsl
  alias Spark.Dsl.Transformer
  alias Steward.Resource.Validations.RequireWitness

  @impl true
  def transform(dsl) do
    with {:ok, validation} <-
           Transformer.build_entity(Dsl, [:validations], :validate,
             validation: {RequireWitness, []},
             on: [:create, :update, :destroy, :action]
           ) do
      {:ok, Transformer.add_entity(dsl, [:validations], validation)}
    end
  end
end
