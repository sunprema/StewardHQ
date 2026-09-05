defmodule StewardWeb.MCPRouteTest do
  @moduledoc """
  Confirms `/mcp` is actually wired to `Steward.MCP.Facade` — the part
  of the mount that's specific to this project. `hermes_mcp`'s own
  session/handshake protocol over that route is its own tested concern,
  not re-verified here.
  """

  use ExUnit.Case, async: true

  test "the /mcp forward route points at Hermes.Server.Transport.StreamableHTTP.Plug for Steward.MCP.Facade" do
    route =
      Enum.find(StewardWeb.Router.__routes__(), fn route ->
        route.path == "/mcp/*_forward_path_info" or route.path == "/mcp"
      end)

    assert route, "no route found forwarding /mcp"
    assert route.plug == Hermes.Server.Transport.StreamableHTTP.Plug
    assert route.plug_opts[:server] == Steward.MCP.Facade
  end

  test "Steward.MCP.Facade is declared in the application's supervision tree" do
    assert Enum.any?(Supervisor.which_children(Steward.Supervisor), fn
             {Steward.MCP.Facade, _pid, _type, _modules} -> true
             _other -> false
           end)
  end
end
