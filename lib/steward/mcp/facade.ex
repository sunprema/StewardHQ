defmodule Steward.MCP.Facade do
  @moduledoc """
  StewardHQ as an MCP server (docs/tech_spec.md §8 "Adoption wedge —
  StewardHQ as an MCP server"; §8 Phase 5 "MCP server facade").

  This is the *proxy* model, not a permit/token-issuer: an agent calls
  an MCP tool, and StewardHQ itself validates the plan, acquires the
  borrow and lease, calls the real backend, and returns a structured
  result — the agent never touches the backend directly, and backend
  credentials never have to leave this process. Every one of the four
  guarantees (§4) depends on StewardHQ being the one making the call;
  handing an agent a bare permit token and trusting it to call the
  backend itself would make the borrow checker advisory and the saga's
  compensation logic unable to know what actually happened. See the
  brainstorm that settled this in the project's history for the full
  argument.

  ## What gets exposed, and how

  Nothing is auto-discovered. Which resources — and therefore which
  capabilities — are reachable from this facade is explicit application
  config, since deciding what an agent can call is a deliberate operator
  decision, not a side effect of declaring a `Steward.Resource`:

      config :steward, Steward.MCP.Facade,
        resources: [
          {MyApp.Invoice, state_attribute: :status},
          MyApp.Order
        ]

  Each configured resource contributes one MCP tool per declared
  capability except `:create` (see `Steward.MCP.Tool`'s moduledoc for
  why), named `"\#{capability}_\#{resource}"` — e.g. `pay_invoice`,
  matching the spec's own running example literally. `state_attribute`
  (default `:status`) names the attribute holding a resource's current
  state, for `Steward.MCP.Tool.initial_states/4`'s pre-fetch.

  ## Mounting

  Add to `Steward.Application`'s supervision tree:

      {Steward.MCP.Facade, transport: :streamable_http}

  and forward a route to it outside the `:browser` pipeline (no CSRF/
  session plugs — this is a JSON-RPC endpoint):

      pipeline :mcp do
        plug :accepts, ["json"]
      end

      scope "/mcp" do
        pipe_through :mcp
        forward "/", to: Hermes.Server.Transport.StreamableHTTP.Plug, server: Steward.MCP.Facade
      end
  """

  use Hermes.Server,
    name: "steward",
    version: "0.1.0",
    capabilities: [:tools]

  alias Hermes.Server.Frame
  alias Hermes.Server.Response
  alias Steward.MCP.Tool
  alias Steward.Resource.Info, as: StewardInfo

  @impl true
  def init(_client_info, frame) do
    frame =
      Enum.reduce(configured_resources(), frame, fn {resource, opts}, frame ->
        register_resource_tools(frame, resource, opts)
      end)

    {:ok, frame}
  end

  @impl true
  def handle_tool_call(tool_name, params, frame) do
    case lookup_tool(frame, tool_name) do
      {:ok, resource, capability_name, state_attribute} ->
        call_tool(resource, capability_name, state_attribute, params, frame)

      :error ->
        {:error, Hermes.MCP.Error.protocol(:method_not_found, %{"tool" => tool_name}), frame}
    end
  end

  # `frame.assigns` is declared as a bare `Enumerable.t()` by Hermes.Server.Frame,
  # so a plain `Map.fetch` here leaves the extracted tuple's field types fully
  # dynamic to Dialyzer. This explicit @spec re-narrows them for every caller.
  @spec lookup_tool(Frame.t(), String.t()) :: {:ok, module(), atom(), atom()} | :error
  defp lookup_tool(frame, tool_name) do
    case Map.fetch(frame.assigns[:steward_tools] || %{}, tool_name) do
      {:ok, {resource, capability_name, state_attribute}} ->
        {:ok, resource, capability_name, state_attribute}

      :error ->
        :error
    end
  end

  defp configured_resources do
    :steward
    |> Application.get_env(__MODULE__, resources: [])
    |> Keyword.get(:resources, [])
    |> Enum.map(&normalize_resource_config/1)
  end

  defp normalize_resource_config({resource, opts}) when is_atom(resource) and is_list(opts),
    do: {resource, opts}

  defp normalize_resource_config(resource) when is_atom(resource), do: {resource, []}

  defp register_resource_tools(frame, resource, opts) do
    state_attribute = Keyword.get(opts, :state_attribute, :status)

    resource
    |> StewardInfo.capabilities()
    |> Enum.reject(&create_action?(resource, &1.name))
    |> Enum.reduce(frame, fn capability, frame ->
      register_tool(frame, resource, capability.name, state_attribute)
    end)
  end

  defp create_action?(resource, capability_name) do
    match?(%{type: :create}, Ash.Resource.Info.action(resource, capability_name))
  end

  defp register_tool(frame, resource, capability_name, state_attribute) do
    tool_name = Tool.name(resource, capability_name)

    tools =
      Map.put(
        frame.assigns[:steward_tools] || %{},
        tool_name,
        {resource, capability_name, state_attribute}
      )

    frame
    |> Frame.register_tool(tool_name,
      description: "Steward-governed `#{capability_name}` action on #{inspect(resource)}.",
      input_schema: Tool.input_schema(resource, capability_name)
    )
    |> Frame.assign(:steward_tools, tools)
  end

  defp call_tool(resource, capability_name, state_attribute, params, frame) do
    {resource_id, args} = Map.pop(params, "resource_id")
    step = Tool.build_step(resource, capability_name, resource_id, args)
    initial_states = Tool.initial_states(resource, capability_name, resource_id, state_attribute)

    case Steward.SagaExecutor.execute([step], initial_states: initial_states) do
      {:ok, result} ->
        response = Response.tool() |> Response.structured(Tool.serialize_result(result))
        {:reply, response, frame}

      error ->
        payload = Tool.error_payload(error)

        response =
          Response.tool()
          |> Response.text("#{payload["reason"]}: #{inspect(payload["detail"])}")
          |> Response.structured(payload)
          |> Map.put(:isError, true)

        {:reply, response, frame}
    end
  end
end
