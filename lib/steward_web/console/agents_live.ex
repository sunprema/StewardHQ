defmodule StewardWeb.Console.AgentsLive do
  @moduledoc """
  Agent tree as a nested list (docs/ux_requirements.md §6.5, design artboard
  1h — option A for open question 3, chosen because §6.5 asks the screen to
  handle 3+ levels and 10+ siblings, which a left-to-right tree does badly).

  Answers: which agents are alive, who spawned whom, what does each hold,
  and — when one died — did the runtime take everything back.

  That last question is the point. An exited node stays in the list for a
  short window with a "released N borrows, M capabilities" summary, because
  that summary is the visible proof of invariant 4: no capability outlives
  its plan. Hiding exits would hide the guarantee.
  """

  use StewardWeb, :live_view

  import StewardWeb.Console.Components

  alias Steward.Console.LiveState
  alias StewardWeb.Console.Layout

  on_mount {StewardWeb.LiveUserAuth, :live_user_required}

  @refresh 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, self(), :tick)

    {:ok,
     socket
     |> assign(
       live_state: :live,
       query: "",
       show_exited: true,
       collapsed: MapSet.new(),
       selected: nil,
       page_title: "Agents · StewardHQ"
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(query: params["q"] || "", selected: params["agent"] || socket.assigns.selected)
     |> load()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, if(socket.assigns.live_state == :live, do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("toggle-live", _params, socket) do
    next = if socket.assigns.live_state == :live, do: :paused, else: :live
    socket = assign(socket, live_state: next)
    {:noreply, if(next == :live, do: load(socket), else: socket)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(query: q) |> load()}
  end

  # The screen already filters as you type, so submitting only means
  # "stop editing" — there is nowhere else to go.
  def handle_event("search-submit", _params, socket), do: {:noreply, socket}

  def handle_event("select", %{"agent" => agent}, socket) do
    {:noreply, socket |> assign(selected: agent) |> load()}
  end

  def handle_event("toggle-exited", _params, socket) do
    {:noreply, socket |> assign(show_exited: not socket.assigns.show_exited) |> load()}
  end

  def handle_event("toggle-node", %{"agent" => agent}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, agent),
        do: MapSet.delete(collapsed, agent),
        else: MapSet.put(collapsed, agent)

    {:noreply, socket |> assign(collapsed: collapsed) |> load()}
  end

  def handle_event("expand-all", _params, socket) do
    {:noreply, socket |> assign(collapsed: MapSet.new()) |> load()}
  end

  defp load(socket) do
    a = socket.assigns
    tree = LiveState.agent_tree()
    rows = tree |> LiveState.flatten() |> visible(a)

    selected =
      a.selected ||
        Enum.find_value(rows, fn
          {_d, :agent, node} -> node.state == :alive && node.kind == :sub_agent && node.agent
          _ -> nil
        end)

    assign(socket,
      rows: rows,
      summary: LiveState.summary(),
      selected: selected,
      selected_node: selected && LiveState.find_agent(selected),
      holdings: selected && LiveState.holdings(selected),
      parent: selected && LiveState.parent_of(selected),
      channel: selected && LiveState.channel_of(selected),
      last_fresh_at: DateTime.utc_now()
    )
  end

  # Hide exited nodes on request, and hide everything beneath a collapsed
  # parent. Depth is carried by the flattened rows, so a collapsed parent
  # simply swallows the deeper rows that follow it.
  defp visible(rows, a) do
    {out, _skip_below} =
      Enum.reduce(rows, {[], nil}, fn {depth, kind, node} = row, {acc, skip_below} ->
        cond do
          skip_below && depth > skip_below ->
            {acc, skip_below}

          kind == :agent and node.state == :exited and not a.show_exited ->
            {acc, skip_below}

          kind == :agent and MapSet.member?(a.collapsed, node.agent) ->
            {[row | acc], depth}

          true ->
            {[row | acc], nil}
        end
      end)

    out |> Enum.reverse() |> drop_childless_channels()
  end

  # A channel whose only children were hidden (exited, or under a collapsed
  # parent) would otherwise render as a bare mailbox row with nothing under
  # it. Drop it: the channel is only interesting as the thing a sub-agent
  # was spawned through.
  defp drop_childless_channels(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reject(fn {{depth, kind, _node}, index} ->
      kind == :channel and not has_child_below?(rows, index, depth)
    end)
    |> Enum.map(fn {row, _index} -> row end)
  end

  defp has_child_below?(rows, index, depth) do
    rows
    |> Enum.drop(index + 1)
    |> Enum.take_while(fn {d, _k, _n} -> d > depth end)
    |> Enum.any?(fn {_d, kind, _n} -> kind == :agent end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layout.shell
      page={:agents}
      persona="Developer / Operator"
      query={@query}
      live_state={@live_state}
      last_fresh_at={@last_fresh_at}
      counts={%{
        borrows: @summary.borrows,
        capabilities: @summary.capabilities,
        agents: @summary.agents
      }}
    >
      <div style="display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:14px;align-items:start">
        <div class="sc-card">
          <div class="sc-card-head">
            <span class="sc-card-title">Agents</span>
            <span class="sc-card-meta" style="margin-left:8px">
              {@summary.agents} alive · {@summary.agents_exited} exited in the last minute
            </span>
            <div style="margin-left:auto;display:flex;gap:10px;align-items:center">
              <button type="button" phx-click="expand-all" class="sc-tab">▾ Expand all</button>
              <button
                type="button"
                phx-click="toggle-exited"
                class="sc-tab"
                aria-selected={to_string(@show_exited)}
              >
                Show exited {if @show_exited, do: "✓", else: ""}
              </button>
            </div>
          </div>

          <.empty
            :if={@rows == []}
            kind={:no_live_state}
            started_at={LiveState.started_at()}
            title="No live agents"
          />

          <table :if={@rows != []} class="sc-tree">
            <thead>
              <tr>
                <th>Agent / channel</th>
                <th>State</th>
                <th>Uptime</th>
                <th>Holds</th>
                <th>Saga</th>
              </tr>
            </thead>
            <tbody>
              <%= for {depth, kind, node} <- @rows do %>
                <.tree_row
                  :if={kind == :agent}
                  depth={depth}
                  node={node}
                  selected={@selected}
                  collapsed={MapSet.member?(@collapsed, node.agent)}
                />
                <.channel_row :if={kind == :channel} depth={depth} channel={node} />
              <% end %>
            </tbody>
          </table>

          <p style="padding:10px 16px;margin:0;font-size:11px;color:var(--sc-ink-3)">
            b = borrows held · c = capabilities held. Exited rows stay visible for
            {LiveState.exit_visibility_window()} s; the release summary is the proof of
            automatic cleanup.
          </p>
        </div>

        <div class="sc-card">
          <.empty :if={is_nil(@selected_node)} title="No node selected">
            Select an agent to see what it holds.
          </.empty>

          <div :if={@selected_node} class="sc-panel">
            <div class="sc-panel-sec">
              <div class="sc-panel-label">Selected node</div>
              <div style="font-weight:600;font-size:14px">{@selected_node.agent}</div>
              <div style="font-size:11.5px;color:var(--sc-ink-3);margin-top:3px">
                <.id value={@selected_node.pid} head={14} tail={0} /> · up
                {duration(@selected_node.uptime)}
              </div>
            </div>

            <div class="sc-panel-sec">
              <dl class="sc-defs" style="grid-template-columns:repeat(2,minmax(0,1fr))">
                <div>
                  <dt>Parent</dt>
                  <dd>{@parent || "—"}</dd>
                </div>
                <div>
                  <dt>Current saga</dt>
                  <dd>
                    <.link
                      navigate={~p"/console/sagas?q=#{@selected_node.saga_id}"}
                      class="sc-link"
                    >
                      {truncate_id(@selected_node.saga_id)}
                    </.link>
                  </dd>
                </div>
              </dl>
            </div>

            <div class="sc-panel-sec">
              <div class="sc-panel-label">
                Borrows held · {length(@holdings.borrows)}
              </div>
              <div :if={@holdings.borrows == []} style="font-size:12px;color:var(--sc-ink-3)">
                Holds no borrow.
              </div>
              <div :for={b <- @holdings.borrows} style="font-size:12px;margin-bottom:8px">
                <.chip status={b.mode} />
                <span style="margin-left:6px">{b.resource}</span>
                <span class="sc-mono" style="font-size:11.5px">{b.resource_id}</span>
                <div style="color:var(--sc-ink-3);font-size:11px;margin-top:3px">
                  token <span class="sc-mono">#{b.lease_token}</span> · expires
                  <.time seconds={DateTime.diff(b.expires_at, DateTime.utc_now())} />
                </div>
              </div>
            </div>

            <div class="sc-panel-sec">
              <div class="sc-panel-label">
                Capabilities held · {length(@holdings.capabilities)}
              </div>
              <div :if={@holdings.capabilities == []} style="font-size:12px;color:var(--sc-ink-3)">
                Holds no capability.
              </div>
              <div :for={c <- @holdings.capabilities} style="font-size:12px;margin-bottom:8px">
                <span style="font-weight:600">{c.action}</span>
                <.id value={c.ref} head={8} tail={4} />
                <.chip status={c.status} />
                <div :if={c.moved_from} class="sc-gap" style="margin-top:6px">
                  moved from <b>{c.moved_from}</b> {relative(c.moved_at)} — the sender no
                  longer holds it.
                </div>
              </div>
            </div>

            <div :if={@channel} class="sc-panel-sec">
              <div class="sc-panel-label">Channel mailbox</div>
              <dl class="sc-defs" style="grid-template-columns:repeat(3,minmax(0,1fr))">
                <div>
                  <dt>Queued</dt>
                  <dd class="sc-mono">{@channel.queued} / {@channel.capacity}</dd>
                </div>
                <div>
                  <dt>Overflow</dt>
                  <dd class="sc-mono">{@channel.overflow}</dd>
                </div>
                <div>
                  <dt>Message</dt>
                  <dd class="sc-mono">{@channel.message}</dd>
                </div>
              </dl>
            </div>

            <div class="sc-panel-sec">
              <.link
                navigate={~p"/console/sagas?q=#{@selected_node.saga_id}"}
                class="sc-link"
              >
                Sagas run by this agent ›
              </.link>
            </div>
          </div>
        </div>
      </div>
    </Layout.shell>
    """
  end

  attr :depth, :integer, required: true
  attr :node, :map, required: true
  attr :selected, :any, default: nil
  attr :collapsed, :boolean, default: false

  defp tree_row(assigns) do
    assigns = assign(assigns, :note, node_note(assigns.node))

    ~H"""
    <tr
      data-kind="agent"
      data-state={@node.state}
      data-selected={to_string(@selected == @node.agent)}
      phx-click="select"
      phx-value-agent={@node.agent}
      style="cursor:pointer"
    >
      <td style={"padding-left:#{12 + @depth * 18}px"}>
        <span class="sc-node">
          <button
            :if={@node.kind == :parent}
            type="button"
            class="sc-twist"
            phx-click="toggle-node"
            phx-value-agent={@node.agent}
            aria-expanded={to_string(not @collapsed)}
            aria-label={"Collapse #{@node.agent}"}
          >
            {if @collapsed, do: "▸", else: "▾"}
          </button>
          <span class="sc-node-name" data-kind={@node.kind}>{@node.agent}</span>
          <span :if={@node.kind == :parent} class="sc-node-meta">
            plan <span class="sc-mono">{@node.plan_id}</span>
          </span>
          <span :if={@node.kind == :sub_agent && is_nil(@note)} class="sc-node-meta">
            sub-agent
          </span>
          <span :if={@note} class="sc-node-meta" style={note_style(@node)}>
            {@note}
          </span>
        </span>
      </td>
      <td><.chip status={@node.state} /></td>
      <td class="sc-mono" style="font-size:11.5px">{uptime(@node)}</td>
      <td>
        <span class="sc-holds">
          <b :if={@node.borrows > 0}>{@node.borrows}</b><span :if={@node.borrows == 0}>0</span> b ·
          <b :if={@node.capabilities > 0}>{@node.capabilities}</b><span :if={@node.capabilities == 0}>0</span> c
        </span>
      </td>
      <td>
        <.link navigate={~p"/console/sagas?q=#{@node.saga_id}"} class="sc-id" style="color:inherit">
          {truncate_id(@node.saga_id)}
        </.link>
      </td>
    </tr>
    """
  end

  attr :depth, :integer, required: true
  attr :channel, :map, required: true

  defp channel_row(assigns) do
    ~H"""
    <tr data-kind="channel">
      <td style={"padding-left:#{12 + @depth * 18}px"} colspan="5">
        <span class="sc-chan">
          <span class="sc-chan-name">{@channel.name}</span>
          <span :if={@channel.closed}>closed</span>
          <span :if={not @channel.closed}>
            {@channel.queued} / {@channel.capacity} · {@channel.overflow}
          </span>
        </span>
      </td>
    </tr>
    """
  end

  # An exited node's note is the release summary — the proof of cleanup.
  defp node_note(%{note: {:released, borrows, caps}}),
    do: "released #{borrows} borrow#{plural(borrows)}, #{caps} capabilit#{plural_y(caps)}"

  defp node_note(%{note: {:waiting_on, resource_id, nil}}), do: "◷ waiting on #{resource_id}"

  defp node_note(%{note: {:waiting_on, resource_id, age}}),
    do: "◷ waiting on #{resource_id} · #{duration(age)}"

  defp node_note(_), do: nil

  defp note_style(%{note: {:waiting_on, _, _}}), do: "color:var(--sc-warn-fg)"
  defp note_style(_), do: nil

  defp uptime(%{state: :exited, exited_ago: ago}), do: "#{duration(ago)} ago"
  defp uptime(%{uptime: seconds}), do: duration(seconds)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp plural_y(1), do: "y"
  defp plural_y(_), do: "ies"
end
