defmodule StewardWeb.Console.OverviewLive do
  @moduledoc """
  Operator landing screen (docs/ux_requirements.md §6.1, design artboard 1a).

  Answers "is the runtime healthy right now, and is anything about to go
  wrong". Fits one laptop screen without scrolling, so every count is a
  tile and every problem is one row in a single attention list.

  Each attention row deep-links to the rows behind it — §4 principle 3,
  "evidence over summary": a count that cannot be opened is not evidence.
  """

  use StewardWeb, :live_view

  import StewardWeb.Console.Components

  alias Steward.Console.Activity
  alias Steward.Console.LiveState
  alias StewardWeb.Console.Layout

  on_mount {StewardWeb.LiveUserAuth, :live_user_required}

  @refresh 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, self(), :tick)

    {:ok, socket |> assign(live_state: :live, query: "") |> load()}
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
    {:noreply, assign(socket, query: q)}
  end

  def handle_event("search-submit", %{"q" => q}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/console/sagas?q=#{q}")}
  end

  defp load(socket) do
    live = LiveState.summary()
    history = Activity.summary()
    errors = Activity.error_counts()

    assign(socket,
      page_title: "Overview · StewardHQ",
      live: live,
      history: history,
      errors: errors,
      error_total: Enum.reduce(errors, 0, fn {_r, c}, acc -> acc + c end),
      attention: attention(live, history),
      recent: Activity.recent(4),
      last_fresh_at: DateTime.utc_now()
    )
  end

  # The attention list is the whole point of the screen: leases about to
  # expire, queues that have aged, caches that disagree with the backend,
  # and sagas that have stopped retrying (§6.1).
  defp attention(_live, history) do
    now = DateTime.utc_now()

    expiring =
      for row <- LiveState.borrow_board(),
          left = DateTime.diff(row.expires_at, now),
          left <= LiveState.expiring_threshold() do
        mode = if Enum.any?(row.holders, &(&1.mode == :exclusive)), do: "exclusive", else: "shared"

        %{
          kind: :expiring,
          label: "#{row.resource} #{row.resource_id} · #{mode} lease",
          resource_id: row.resource_id,
          value: "in " <> duration(left),
          tone: "warn",
          link: ~p"/console/borrows",
          link_label: "Borrow board ›",
          sort: left
        }
      end

    queues =
      for row <- LiveState.borrow_board(),
          waiter <- row.waiters,
          age = DateTime.diff(now, waiter.since),
          age >= LiveState.queue_threshold() do
        count = length(row.waiters)
        mode = waiter.mode

        %{
          kind: :queue,
          label:
            "#{row.resource} #{row.resource_id} · #{count} #{mode} waiter#{plural(count)}",
          resource_id: row.resource_id,
          value: duration(age),
          tone: "warn",
          link: ~p"/console/borrows",
          link_label: "Borrow board ›",
          sort: 1_000 - age
        }
      end

    conflicted =
      for record <- LiveState.conflicted_shadows() do
        %{
          kind: :conflicted,
          label:
            "#{record.resource} #{record.resource_id} · cache v#{record.cached_version}, backend v#{record.backend_version}",
          resource_id: record.resource_id,
          value: duration(DateTime.diff(now, record.synced_at)),
          tone: "err",
          link: nil,
          link_label: "Shadow records ›",
          sort: 2_000
        }
      end

    dead =
      for saga <- history.dead_letter do
        %{
          kind: :dead_letter,
          label:
            "Saga #{truncate_id(saga.id)} · #{saga.tool} · #{saga.attempts} of #{saga.attempts} attempts",
          resource_id: nil,
          value: relative_short(saga.finished_at, now),
          tone: "dead",
          link: ~p"/console/sagas/#{saga.id}",
          link_label: "Saga ›",
          sort: 3_000
        }
      end

    Enum.sort_by(expiring ++ queues ++ conflicted ++ dead, & &1.sort)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp relative_short(nil, _now), do: "—"
  defp relative_short(at, now), do: duration(DateTime.diff(now, at))

  @impl true
  def render(assigns) do
    ~H"""
    <Layout.shell
      page={:overview}
      persona="Operator"
      query={@query}
      live_state={@live_state}
      last_fresh_at={@last_fresh_at}
      counts={%{
        borrows: @live.borrows,
        borrows_tone: @live.waiters > 0 && "warn",
        capabilities: @live.capabilities,
        agents: @live.agents,
        errors: @error_total
      }}
    >
      <div class="sc-pagehead">
        <h1>Overview</h1>
        <p>{headline(@attention)}</p>
      </div>

      <div class="sc-tiles">
        <.tile label="Active borrows" value={@live.borrows} navigate={~p"/console/borrows"}>
          <:foot>
            <div class="sc-tile-chips">
              <.chip status={:shared} label={"#{@live.shared} shared"} />
              <.chip status={:exclusive} label={"#{@live.exclusive} exclusive"} />
            </div>
          </:foot>
        </.tile>

        <.tile
          label="Queued waiters"
          value={@live.waiters}
          tone={@live.waiters > 0 && "warn"}
          navigate={~p"/console/borrows?filter=queued"}
        >
          <:foot>
            <div class="sc-tile-foot" data-tone={@live.waiters > 0 && "warn"}>
              <%= if @live.oldest_waiter do %>
                oldest waiting <span class="sc-mono">{duration(@live.oldest_waiter)}</span>
              <% else %>
                no queue
              <% end %>
            </div>
          </:foot>
        </.tile>

        <.tile label="Active capabilities" value={@live.capabilities}>
          <:foot>
            <div class="sc-tile-foot">
              {@live.capabilities_moved_recently} moved in the last minute
            </div>
          </:foot>
        </.tile>

        <.tile label="Running sagas" value={@history.running} navigate={~p"/console/sagas?status=running"}>
          <:foot>
            <div class="sc-tile-foot">{@history.completed_today} completed today</div>
          </:foot>
        </.tile>

        <.tile label="Live agents" value={@live.agents} navigate={~p"/console/agents"}>
          <:foot>
            <div class="sc-tile-foot">
              {@live.agent_parents} parents · {@live.agent_subs} sub-agents
            </div>
          </:foot>
        </.tile>
      </div>

      <div style="display:grid;grid-template-columns:minmax(0,1.5fr) minmax(0,1fr);gap:14px;min-height:0">
        <div class="sc-card">
          <div class="sc-card-head">
            <span class="sc-card-title">Attention</span>
            <.chip
              :if={@attention != []}
              tone="warn"
              label={to_string(length(@attention))}
              glyph={nil}
            />
            <span class="sc-card-meta">
              thresholds: lease &lt; {LiveState.expiring_threshold()} s · queue &gt; {LiveState.queue_threshold()} s
            </span>
          </div>

          <.empty :if={@attention == []} kind={:healthy}>
            Every lease has room, no queue has aged, and no cache disagrees
            with its backend.
          </.empty>

          <.attention_row :for={item <- @attention} item={item} />
        </div>

        <div class="sc-card">
          <div class="sc-card-head">
            <span class="sc-card-title">Errors · last hour</span>
            <span class="sc-card-meta">{@error_total} total</span>
          </div>

          <.empty :if={@errors == []} title="No errors in the last hour">
            Every step that ran held a borrow, wrote under a live lease, and
            left its capability in a legal state.
          </.empty>

          <div
            :if={@errors != []}
            style="padding:12px 16px;display:flex;flex-direction:column;gap:10px;font-size:12px"
          >
            <div :for={{reason, count} <- @errors} class="sc-bar-row">
              <span class="sc-bar-name" title={error_subtitle(reason)}>{reason}</span>
              <div class="sc-bar-track">
                <div class="sc-bar-fill" style={"width:#{bar_width(count, @error_total)}%"}></div>
              </div>
              <span class="sc-bar-count">{count}</span>
            </div>
            <div style="color:var(--sc-ink-3);font-size:11px;margin-top:2px">
              Most from tool
              <span class="sc-mono" style="color:var(--sc-ink-2)">{top_tool(@recent)}</span>
              · <span class="sc-link">Errors ›</span>
            </div>
          </div>
        </div>
      </div>

      <div class="sc-strip">
        <span style="font-weight:600;font-size:13px;margin-right:6px;white-space:nowrap">Recent</span>

        <span :if={@recent == []} style="font-size:12px;color:var(--sc-ink-3)">
          No sagas have finished yet — see <span class="sc-mono">docs/cookbook.md</span> to run one.
        </span>

        <.link :for={saga <- @recent} navigate={~p"/console/sagas/#{saga.id}"} class="sc-pill">
          <span class="sc-pill-mark" data-tone={pill_tone(saga.status)} aria-hidden="true">
            {pill_glyph(saga.status)}
          </span>
          <span class="sc-mono" style="font-size:11.5px;font-weight:500">
            {truncate_id(saga.id)}
          </span>
          <span class="sc-pill-meta">
            {saga.tool} · {relative_short(saga.finished_at, DateTime.utc_now())}
          </span>
        </.link>

        <.link navigate={~p"/console/sagas"} class="sc-link" style="margin-left:auto">
          All sagas ›
        </.link>
      </div>
    </Layout.shell>
    """
  end

  attr :item, :map, required: true

  defp attention_row(assigns) do
    ~H"""
    <div class="sc-row sc-attn">
      <.chip status={@item.kind} />
      <span>{@item.label}</span>
      <span class="sc-time" data-tone={@item.tone == "warn" && "warn"}>{@item.value}</span>
      <.link :if={@item.link} navigate={@item.link} class="sc-link">{@item.link_label}</.link>
      <span
        :if={is_nil(@item.link)}
        class="sc-link"
        style="opacity:.5"
        title="Shadow records is designed but not built yet"
      >
        {@item.link_label}
      </span>
    </div>
    """
  end

  defp headline([]), do: "Runtime healthy · nothing needs attention"

  defp headline(items),
    do: "Runtime healthy · #{length(items)} item#{plural(length(items))} need attention"

  defp bar_width(_count, 0), do: 0
  defp bar_width(count, total), do: max(round(count / total * 100), 4)

  defp pill_tone(:completed), do: "ok"
  defp pill_tone(_), do: "err"

  defp pill_glyph(:completed), do: "✓"
  defp pill_glyph(_), do: "✕"

  defp top_tool([]), do: "—"

  defp top_tool(sagas) do
    sagas
    |> Enum.filter(&(&1.status in [:failed, :dead_letter]))
    |> Enum.map(& &1.tool)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_tool, count} -> count end, fn -> {"—", 0} end)
    |> elem(0)
  end
end
