defmodule Steward.Sagas.ActionDispatcher do
  @moduledoc """
  Calls a named Ash action on a stewarded resource generically, dispatched
  by the action's own declared type (docs/tech_spec.md §8 Phase 4 "Reactor
  integration").

  A plan step only names a resource module, a `resource_id`, and an
  action name — it doesn't know (and shouldn't need to know) whether that
  action is a create/read/update/destroy/generic action. This is the one
  place that distinction is resolved, so `Steward.Sagas.StepRunner` can
  stay a plain Reactor step.

  Every call carries `context: %{steward: %{borrow_token: ...}}` (and a
  lease, for mutations) so the `Steward.Resource.Validations.RequireWitness`
  and `Steward.Changes.EnforceFencing` checks a resource declares are
  satisfied — there is still no bypass path (CLAUDE.md invariant 1).
  """

  alias Ash.Resource.Info, as: ResourceInfo

  @doc """
  Runs `resource`'s `action` for `resource_id`, with `args` as the
  action's accepted attributes/arguments and `context` merged into every
  call. `:create` ignores `resource_id` (there is nothing to fetch yet).
  """
  @spec call(module(), term(), atom(), map(), map()) :: {:ok, term()} | {:error, term()}
  def call(resource, resource_id, action, args, context) do
    case ResourceInfo.action(resource, action) do
      nil ->
        {:error, {:unknown_action, resource, action}}

      %{type: :create} ->
        resource |> Ash.Changeset.for_create(action, args, context: context) |> Ash.create()

      %{type: :read} ->
        Ash.get(resource, resource_id, action: action, context: context)

      %{type: :update} ->
        with {:ok, record} <- Ash.get(resource, resource_id, context: context) do
          record |> Ash.Changeset.for_update(action, args, context: context) |> Ash.update()
        end

      %{type: :destroy} ->
        with {:ok, record} <- Ash.get(resource, resource_id, context: context) do
          record |> Ash.Changeset.for_destroy(action, args, context: context) |> Ash.destroy()
        end

      %{type: :action} ->
        resource
        |> Ash.ActionInput.for_action(action, args, context: context)
        |> Ash.run_action()
    end
  end
end
