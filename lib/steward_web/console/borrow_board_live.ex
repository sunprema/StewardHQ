defmodule StewardWeb.Console.BorrowBoardLive do
  @moduledoc """
  Live borrow board, resource-centric card grid (docs/ux_requirements.md
  §6.3, design artboard 1f — option B for open question 1, chosen because
  contention is the thing this screen exists to make visible).

  Answers: who holds what right now, is anyone waiting, and is anything
  about to expire. One card per resource with any live state; holders and
  waiters are listed on the card rather than hidden behind an expander, so
  contention reads at a glance.

  Two rules this screen must not break:

    * **No release action, ever** (§6.3 non-goals). Nothing here mutates
      runtime state; pausing only stops the screen refreshing.
    * **Empty is not blank** (§4 principle 2). Borrows and leases are
      in-memory and vanish on restart, so an empty board says so and names
      the runtime start time.
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
       sort: :expiry,
       mode_filter: :any,
       queued_only: false,
       expiring_only: false,
       page_title: "Borrow board · StewardHQ"
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       query: params["q"] || "",
       queued_only: params["filter"] == "queued",
       expiring_only: params["filter"] == "expiring"
     )
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

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(sort: String.to_existing_atom(sort)) |> load()}
  end

  def handle_event("mode", %{"mode" => mode}, socket) do
    {:noreply, socket |> assign(mode_filter: String.to_existing_atom(mode)) |> load()}
  end

  def handle_event("toggle-queued", _params, socket) do
    {:noreply, socket |> assign(queued_only: not socket.assigns.queued_only) |> load()}
  end

  def handle_event("toggle-expiring", _params, socket) do
    {:noreply, socket |> assign(expiring_only: not socket.assigns.expiring_only) |> load()}
  end

  defp load(socket) do
    a = socket.assigns
    now = DateTime.utc_now()

    rows =
      LiveState.borrow_board()
      |> Enum.map(&decorate(&1, now))
      |> filter(a)
      |> sort(a.sort)

    assign(socket,
      rows: rows,
      summary: LiveState.summary(),
      now: now,
      last_fresh_at: (a.live_state == :live && now) || a[:last_fresh_at] || now
    )
  end

  defp decorate(row, now) do
    left = DateTime.diff(row.expires_at, now)

    row
    |> Map.put(:left, left)
    |> Map.put(:expiring?, left <= LiveState.expiring_threshold())
    |> Map.put(:pct, percent(left, row.lease_ttl))
    |> Map.put(
      :waiters,
      Enum.map(row.waiters, fn w ->
        Map.put(w, :age, DateTime.diff(now, w.since))
      end)
    )
    |> Map.put(
      :holders,
      Enum.map(row.holders, fn h ->
        Map.put(h, :age, DateTime.diff(now, h.since))
      end)
    )
  end

  defp percent(left, ttl) when is_integer(ttl) and ttl > 0 do
    left |> Kernel./(ttl) |> Kernel.*(100) |> round() |> min(100) |> max(0)
  end

  defp percent(_left, _ttl), do: 100

  defp filter(rows, a) do
    rows
    |> then(fn rows -> if a.queued_only, do: Enum.filter(rows, &(&1.waiters != [])), else: rows end)
    |> then(fn rows -> if a.expiring_only, do: Enum.filter(rows, & &1.expiring?), else: rows end)
    |> then(fn rows ->
      case a.mode_filter do
        :any -> rows
        mode -> Enum.filter(rows, fn r -> Enum.any?(r.holders, &(&1.mode == mode)) end)
      end
    end)
    |> then(fn rows ->
      case String.trim(a.query || "") do
        "" ->
          rows

        term ->
          term = String.downcase(term)

          Enum.filter(rows, fn r ->
            String.contains?(String.downcase(r.resource_id), term) or
              String.contains?(String.downcase(r.resource), term) or
              Enum.any?(r.holders ++ r.waiters, fn p ->
                p.agent && String.contains?(String.downcase(p.agent), term)
              end)
          end)
      end
    end)
  end

  defp sort(rows, :expiry), do: Enum.sort_by(rows, & &1.left)

  defp sort(rows, :queue),
    do: Enum.sort_by(rows, fn r -> -(r.waiters |> Enum.map(& &1.age) |> Enum.max(fn -> 0 end)) end)

  defp sort(rows, :type), do: Enum.sort_by(rows, &{&1.resource, &1.resource_id})

  @impl true
  def render(assigns) do
    ~H"""
    <Layout.shell
      page={:borrows}
      persona="Operator"
      query={@query}
      live_state={@live_state}
      last_fresh_at={@last_fresh_at}
      counts={%{
        borrows: @summary.borrows,
        borrows_tone: @summary.waiters > 0 && "warn",
        capabilities: @summary.capabilities,
        agents: @summary.agents
      }}
    >
      <div class="sc-pagehead">
        <h1>Borrow board</h1>
        <p>
          {@summary.resources_live} resource{plural(@summary.resources_live)} with live state ·
          {@summary.borrows} borrow{plural(@summary.borrows)} · {@summary.waiters} waiting
        </p>

        <form phx-change="sort" style="margin-left:auto;font-size:12px;color:var(--sc-ink-3)">
          Sort · <select name="sort" class="sc-select">
            <option value="expiry" selected={@sort == :expiry}>Expiry, soonest</option>
            <option value="queue" selected={@sort == :queue}>Queue age</option>
            <option value="type" selected={@sort == :type}>Resource type</option>
          </select>
        </form>
      </div>

      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--sc-ink-3)">
        <form phx-change="mode">
          Mode · <select name="mode" class="sc-select">
            <option value="any" selected={@mode_filter == :any}>Any</option>
            <option value="exclusive" selected={@mode_filter == :exclusive}>Exclusive</option>
            <option value="shared" selected={@mode_filter == :shared}>Shared</option>
          </select>
        </form>

        <button
          type="button"
          phx-click="toggle-queued"
          class="sc-chip"
          data-tone={@queued_only && "warn"}
          style="cursor:pointer;border:1px solid var(--sc-border);font-family:inherit"
        >
          <span class="sc-chip-glyph" aria-hidden="true">◷</span>Has queue
        </button>

        <button
          type="button"
          phx-click="toggle-expiring"
          class="sc-chip"
          data-tone={@expiring_only && "warn"}
          style="cursor:pointer;border:1px solid var(--sc-border);font-family:inherit"
        >
          <span class="sc-chip-glyph" aria-hidden="true">▲</span>Expiring soon
        </button>
      </div>

      <div :if={@rows == []} class="sc-card">
        <.empty
          :if={@summary.resources_live == 0}
          kind={:no_live_state}
          started_at={LiveState.started_at()}
        />
        <.empty
          :if={@summary.resources_live > 0}
          title="Nothing matches these filters"
        >
          {@summary.resources_live} resources hold live state right now.
        </.empty>
      </div>

      <div :if={@rows != []} class="sc-grid">
        <div :for={row <- @rows} class="sc-bcard" data-expiring={to_string(row.expiring?)}>
          <div class="sc-bcard-head">
            <div style="min-width:0">
              <div class="sc-bcard-type">{row.resource}</div>
              <div class="sc-bcard-id">
                <.id value={row.resource_id} head={20} tail={0} />
              </div>
            </div>
            <.chip
              tone={(row.expiring? && "warn") || "ok"}
              glyph={row.expiring? && "▲"}
              label={"expires " <> duration(row.left)}
              class="ml-auto"
            />
          </div>

          <div
            class="sc-lease"
            data-expiring={to_string(row.expiring?)}
            role="img"
            aria-label={"Lease #{row.pct}% remaining, token #{row.lease_token}"}
          >
            <div
              class="sc-lease-fill"
              data-expiring={to_string(row.expiring?)}
              style={"width:#{row.pct}%"}
            >
            </div>
          </div>

          <div class="sc-parties">
            <div
              :for={h <- row.holders}
              class="sc-party"
              data-role="holds"
              data-mode={h.mode}
            >
              <span class="sc-party-role">holds</span>
              <span class="sc-party-mode" data-mode={h.mode} aria-hidden="true">
                {mode_glyph(h.mode)}
              </span>
              <span class="sr-only">{h.mode}</span>
              <span :if={h.agent} class="sc-party-name">{h.agent}</span>
              <span :if={is_nil(h.agent)} class="sc-party-pid">{h.pid}</span>
              <span class="sc-party-meta">
                #{row.lease_token} · {duration(h.age)}
              </span>
            </div>

            <div :for={w <- row.waiters} class="sc-party" data-role="waits">
              <span class="sc-party-role">waits</span>
              <span class="sc-party-mode" data-mode={w.mode} aria-hidden="true">
                {mode_glyph(w.mode)}
              </span>
              <span class="sr-only">{w.mode}</span>
              <span :if={w.agent} class="sc-party-name">{w.agent}</span>
              <span :if={is_nil(w.agent)} class="sc-party-pid">{w.pid}</span>
              <span
                class="sc-party-meta"
                data-tone={w.age >= LiveState.queue_threshold() && "warn"}
              >
                {if w.age >= LiveState.queue_threshold(), do: "◷ ", else: ""}{duration(w.age)}
              </span>
            </div>

            <div :if={row.waiters == []} class="sc-noqueue">No queue</div>
          </div>

          <.link
            navigate={~p"/console/sagas?resource_id=#{row.resource_id}"}
            class="sc-link"
            style="margin-top:auto"
          >
            Recent sagas ›
          </.link>
        </div>
      </div>

      <p style="font-size:11px;color:var(--sc-ink-3);margin:0">
        Resources with no live state are not shown.
        {@summary.resources_known} resources known · {@summary.resources_live} live.
        Read-only: a borrow is released by the runtime, never from here.
      </p>
    </Layout.shell>
    """
  end

  defp mode_glyph(:exclusive), do: "◆"
  defp mode_glyph(:shared), do: "◇"
  defp mode_glyph(_), do: "•"

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
