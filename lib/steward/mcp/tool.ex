defmodule Steward.MCP.Tool do
  @moduledoc """
  Translation layer between one MCP tool call and one witnessed, leased,
  fenced single-step plan (docs/tech_spec.md §8 Phase 5: "each MCP tool
  call is auto-wrapped as a single-step plan — witness required, lease
  acquired, fencing applied, structured error returned on failure").

  Deliberately pure and side-effect-free (besides the one live read in
  `initial_states/4`) so it can be tested without a running
  `Hermes.Server` — `Steward.MCP.Facade` is the thin process-facing
  wrapper around these functions.

  ## Why `initial_states/4` exists

  `Steward.PlanValidator` simulates a plan's state-machine transitions
  starting from each resource's *declared* initial state unless told
  otherwise — correct for a multi-step plan an agent assembled with its
  own tracked observations, wrong for one ad hoc MCP call, where every
  call past the first would look like an illegal transition. So before
  dispatching, the facade fetches the record's actual current state (a
  plain, unwitnessed read — reads are exempt from borrow witnessing by
  design, see `Steward.Resource.Transformers.RequireWitness`) and feeds
  it to the validator as an override.

  There is no DSL-declared attribute naming which field holds a
  resource's current state (`Steward.Resource`'s `state_machine` block
  only knows state *names*, not storage) — that mapping is a
  facade-level convention: `state_attribute:` per configured resource,
  defaulting to `:status`, matching every example in this codebase so
  far.

  ## Deliberately out of scope for v1

  `:create` actions are never exposed as tools — `Steward.MCP.Facade`
  filters them out before this module ever sees them. The whole
  plan/borrow model assumes an already-identified resource (a plan step
  requires `:resource_id`); "create" doesn't fit that shape without a
  larger design change, so it's a documented limitation, not a silent
  gap.

  Only an action's declared `argument`s become tool input fields —
  never its `accept`ed attributes. Some actions declare `accept []`
  specifically to lock out direct attribute writes and route state
  changes only through their own `change set_attribute` (see
  `Steward.Test.Examples.Invoice`); blindly exposing whatever a
  resource's default accept-list happens to be would be an unreviewed
  trust decision this module isn't in a position to make.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias Steward.PlanValidator
  alias Steward.Resource.Info, as: StewardInfo

  @doc "The MCP tool name for `capability_name` on `resource` — e.g. `pay_invoice`."
  @spec name(module(), atom()) :: String.t()
  def name(resource, capability_name), do: "#{capability_name}_#{resource_slug(resource)}"

  defp resource_slug(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore()
  end

  @doc """
  The Peri-style input schema (per `Hermes.Server.Frame.register_tool/3`)
  for calling `capability_name` on `resource`: `resource_id` (always
  required — see moduledoc on `:create`) plus one field per the
  underlying Ash action's declared arguments.
  """
  @spec input_schema(module(), atom()) :: map()
  def input_schema(resource, capability_name) do
    action = ResourceInfo.action(resource, capability_name)

    Enum.reduce(action.arguments, %{resource_id: {:required, :string}}, fn argument, schema ->
      Map.put(schema, argument.name, argument_field(argument))
    end)
  end

  defp argument_field(argument) do
    base = peri_type(argument.type)

    field =
      if argument.description,
        do: {:mcp_field, base, description: argument.description},
        else: base

    if argument.allow_nil? == false, do: {:required, field}, else: field
  end

  defp peri_type(Ash.Type.Integer), do: :integer
  defp peri_type(Ash.Type.Boolean), do: :boolean
  defp peri_type(Ash.Type.Float), do: :float
  # Every other Ash type (decimal, uuid, atom, date/datetime, ...) has no
  # clean JSON-native equivalent; accept it as a string and let Ash's own
  # casting turn it into the real type, the same way it already does for
  # any web/JSON-facing input.
  defp peri_type(_other), do: :string

  @doc """
  Builds the single-step plan `Steward.SagaExecutor.execute/2` runs for
  one MCP tool call. `observed_at` is always "now" — there is no earlier
  observation to distrust in a one-shot call, so freshness is trivially
  satisfied by construction, not bypassed.
  """
  @spec build_step(module(), atom(), term(), map()) :: PlanValidator.step()
  def build_step(resource, capability_name, resource_id, args)
      when is_atom(resource) and is_atom(capability_name) and is_map(args) do
    %{
      # A UUID, not a reference: unlike a plan an agent assembles and
      # holds only in memory, this one gets persisted as part of a
      # Steward.Sagas.Saga's JSON `:plan` column — a reference would
      # fail Jason encoding the moment the saga tries to save.
      id: Ash.UUID.generate(),
      resource: resource,
      resource_id: resource_id,
      action: capability_name,
      args: args,
      observed_at: DateTime.utc_now()
    }
  end

  @doc """
  Looks up `resource_id`'s actual current value of `state_attribute` and
  returns it as a `Steward.PlanValidator.validate/2` `:initial_states`
  override — but only when `capability_name` is a declared state
  transition; for anything else (a plain read, a non-state-machine
  action) this is a no-op, matching `Steward.PlanValidator`'s own
  behavior of ignoring steps with no matching transition.
  """
  @spec initial_states(module(), atom(), term(), atom()) :: %{{module(), term()} => atom()}
  def initial_states(resource, capability_name, resource_id, state_attribute) do
    with %Steward.Resource.Transition{} <- StewardInfo.transition(resource, capability_name),
         {:ok, record} <- Ash.get(resource, resource_id) do
      %{{resource, resource_id} => Map.get(record, state_attribute)}
    else
      _not_a_transition_or_not_found -> %{}
    end
  end

  @doc """
  Converts a successful `Steward.SagaExecutor.execute/2` result into a
  JSON-safe map for the tool response's structured content. Most
  capabilities return the acted-on Ash resource struct (only its public
  attributes are exposed); a generic action (e.g. one with no `:returns`
  resource) returns whatever bare value it produced instead.
  """
  @spec serialize_result(term()) :: map()
  def serialize_result(%resource{} = record) when is_atom(resource) do
    case ResourceInfo.public_attributes(resource) do
      [] ->
        %{"result" => serialize_value(record)}

      attributes ->
        Map.new(attributes, fn attribute ->
          {to_string(attribute.name), serialize_value(Map.get(record, attribute.name))}
        end)
    end
  end

  def serialize_result(other), do: %{"result" => serialize_value(other)}

  defp serialize_value(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp serialize_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp serialize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp serialize_value(nil), do: nil
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_value(value), do: value

  @doc """
  Unwraps whatever shape `Steward.SagaExecutor.execute/2` failed with
  into a flat, JSON-safe `%{"reason" => ..., "detail" => ...}` map —
  spec §4.4's structured taxonomy, translated for a transport that
  can't carry raw Elixir terms.

  Handles, in order: a plan-validation failure (`{:error, atom, detail}`,
  straight from `Steward.PlanValidator`), a borrow-acquisition failure
  (`{:error, {:borrow_failed, key, reason}}`, from
  `Steward.SagaExecutor`), and a mid-run step failure, which Reactor
  wraps in one of `RunStepError`/`CompensateStepError`/`UndoStepError` —
  all three carry the real reason under an `:error` field (verified
  against `reactor`'s own source), so this unwraps generically via that
  shared field rather than naming each wrapper struct.
  """
  @spec error_payload(term()) :: %{String.t() => term()}
  def error_payload({:error, reason, detail}) when is_atom(reason) do
    %{"reason" => to_string(reason), "detail" => safe_inspect(detail)}
  end

  def error_payload({:error, {:borrow_failed, {resource, resource_id}, reason}}) do
    %{
      "reason" => "borrow_failed",
      "detail" => %{
        "resource" => inspect(resource),
        "resource_id" => safe_inspect(resource_id),
        "reason" => safe_inspect(reason)
      }
    }
  end

  def error_payload({:error, other}) do
    case unwrap(other) do
      {reason, detail} when is_atom(reason) ->
        %{"reason" => to_string(reason), "detail" => safe_inspect(detail)}

      reason when is_atom(reason) ->
        %{"reason" => to_string(reason)}

      unrecognized ->
        %{"reason" => "invalid", "detail" => safe_inspect(unrecognized)}
    end
  end

  defp unwrap(%Reactor.Error.Invalid{errors: [first | _rest]}), do: unwrap(first)
  defp unwrap(%{error: inner}), do: unwrap(inner)
  defp unwrap(other), do: other

  defp safe_inspect(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp safe_inspect(value), do: inspect(value)
end
