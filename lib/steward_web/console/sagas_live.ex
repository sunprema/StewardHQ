defmodule StewardWeb.Console.SagasLive do
  @moduledoc """
  Interaction timeline, list level (docs/ux_requirements.md §6.2, design
  artboard 1b).

  The most-used investigative screen: what did agents do, and which runs
  failed. Everything here is durable history from Postgres — no live state,
  so no countdown and no "no live state" empty case.
  """

  use StewardWeb, :live_view

  import StewardWeb.Console.Components

  alias Steward.Console.Activity
  alias Steward.Console.LiveState
  alias StewardWeb.Console.Layout

  on_mount {StewardWeb.LiveUserAuth, :live_user_required}

  @ranges [
    {"1 h", 3_600},
    {"Last 24 h", 86_400},
    {"7 d", 604_800},
    {"All", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, live_state: :live, page_title: "Sagas · StewardHQ")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      status: atom_param(params["status"]),
      resource: presence(params["resource"]),
      resource_id: presence(params["resource_id"]),
      has_errors: params["has_errors"] == "true",
      range: int_param(params["range"], 86_400),
      sort: atom_param(params["sort"]) || :started,
      query: presence(params["q"]) || ""
    }

    {:noreply, socket |> assign(filters: filters, query: filters.query) |> load()}
  end

  defp load(socket) do
    f = socket.assigns.filters

    rows =
      Activity.list_sagas(
        status: f.status,
        resource: f.resource,
        resource_id: f.resource_id,
        has_errors: f.has_errors,
        since: f.range && DateTime.add(DateTime.utc_now(), -f.range, :second),
        query: f.query,
        sort: f.sort
      )

    assign(socket,
      rows: rows,
      resource_types: rows |> Enum.flat_map(& &1.resources) |> Enum.uniq() |> Enum.sort(),
      last_fresh_at: DateTime.utc_now()
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    # Filter in place while typing; patching per keystroke would fill the
    # browser history with one entry per character.
    {:noreply,
     socket
     |> assign(query: q, filters: %{socket.assigns.filters | query: q})
     |> load()}
  end

  def handle_event("search-submit", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: path(socket, %{q: q}))}
  end

  def handle_event("filter", params, socket) do
    changes =
      params
      |> Map.take(~w(status resource sort range))
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), presence(v)} end)

    {:noreply, push_patch(socket, to: path(socket, changes))}
  end

  def handle_event("toggle-errors", _params, socket) do
    next = not socket.assigns.filters.has_errors
    {:noreply, push_patch(socket, to: path(socket, %{has_errors: next && "true"}))}
  end

  def handle_event("toggle-live", _params, socket), do: {:noreply, socket}

  defp path(socket, changes) do
    f = socket.assigns.filters

    current = %{
      status: f.status,
      resource: f.resource,
      resource_id: f.resource_id,
      has_errors: f.has_errors && "true",
      range: f.range,
      sort: f.sort != :started && f.sort,
      q: presence(f.query)
    }

    params =
      current
      |> Map.merge(changes)
      |> Enum.reject(fn {_k, v} -> v in [nil, false, "", :any] end)
      |> Map.new(fn {k, v} -> {k, to_string(v)} end)

    ~p"/console/sagas?#{params}"
  end

  defp atom_param(nil), do: nil
  defp atom_param(""), do: nil

  defp atom_param(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp int_param(nil, default), do: default

  defp int_param(value, default) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Layout.shell
      page={:sagas}
      persona="Agent developer"
      query={@query}
      live_state={@live_state}
      last_fresh_at={@last_fresh_at}
      counts={%{borrows: LiveState.summary().borrows}}
    >
      <div class="sc-pagehead">
        <h1>Sagas</h1>
        <p>Durable history · {length(@rows)} saga{plural(length(@rows))} in range</p>
      </div>

      <form
        phx-change="filter"
        style="display:flex;align-items:center;gap:18px;flex-wrap:wrap;font-size:12px;color:var(--sc-ink-3)"
      >
        <label>
          Status · <select name="status" class="sc-select">
            <option value="" selected={is_nil(@filters.status)}>Any</option>
            <option
              :for={s <- [:running, :completed, :failed, :dead_letter]}
              value={s}
              selected={@filters.status == s}
            >
              {elem(status_meta(s), 2)}
            </option>
          </select>
        </label>

        <label>
          Resource type · <select name="resource" class="sc-select">
            <option value="" selected={is_nil(@filters.resource)}>Any</option>
            <option :for={r <- @resource_types} value={r} selected={@filters.resource == r}>
              {r}
            </option>
          </select>
        </label>

        <label>
          Time · <select name="range" class="sc-select">
            <option
              :for={{label, seconds} <- ranges()}
              value={seconds}
              selected={@filters.range == seconds}
            >
              {label}
            </option>
          </select>
        </label>

        <label>
          Sort · <select name="sort" class="sc-select">
            <option value="started" selected={@filters.sort == :started}>Started, newest</option>
            <option value="duration" selected={@filters.sort == :duration}>Duration, longest</option>
          </select>
        </label>

        <button
          type="button"
          phx-click="toggle-errors"
          class="sc-chip"
          data-tone={@filters.has_errors && "err"}
          style="cursor:pointer;border:1px solid var(--sc-border);font-family:inherit"
        >
          <span class="sc-chip-glyph" aria-hidden="true">✕</span>Has errors
        </button>
      </form>

      <div class="sc-card">
        <.empty :if={@rows == []} title={empty_title(@filters)}>
          <span :if={no_filters?(@filters)}>
            Every MCP tool call produces one saga. See
            <span class="sc-mono">docs/cookbook.md</span> to run one.
          </span>
          <span :if={not no_filters?(@filters)}>
            No saga in this range matches these filters.
          </span>
        </.empty>

        <table :if={@rows != []} class="sc-table">
          <thead>
            <tr>
              <th>Saga</th>
              <th>Status</th>
              <th>Agent / tool</th>
              <th>Resources</th>
              <th>Steps</th>
              <th>Attempts</th>
              <th>Started</th>
              <th>Duration</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={saga <- @rows}>
              <td>
                <.link navigate={~p"/console/sagas/#{saga.id}"} class="sc-id" style="color:inherit">
                  {truncate_id(saga.id)}
                </.link>
              </td>
              <td><.chip status={saga.status} /></td>
              <td>
                <span class="sc-mono" style="font-size:12px">{saga.tool}</span>
                <span style="color:var(--sc-ink-3);font-size:11px">tool</span>
              </td>
              <td>
                <span :for={r <- saga.resources} style="margin-right:6px">{r}</span>
                <span :if={saga.resources == []} style="color:var(--sc-ink-3)">—</span>
              </td>
              <td><.step_breakdown counts={saga.step_counts} /></td>
              <td class="sc-mono" style="font-size:12px">{saga.attempts} / 5</td>
              <td><.time at={saga.inserted_at} /></td>
              <td class="sc-mono" style="font-size:12px">
                {if saga.status == :running, do: "—", else: duration_ms(saga.duration_ms)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p style="font-size:11px;color:var(--sc-ink-3);margin:0">
        <span style="color:var(--sc-ok-fg)">✓</span> succeeded ·
        <span style="color:var(--sc-err-fg)">✕</span> failed ·
        <span style="color:var(--sc-dead-fg)">↶</span> undone ·
        <span style="color:var(--sc-ink-3)">○</span> pending. Agent names on sagas are planned;
        tool name shown until then.
      </p>
    </Layout.shell>
    """
  end

  attr :counts, :map, required: true

  defp step_breakdown(assigns) do
    ~H"""
    <span style="font-size:12px;display:inline-flex;gap:8px;flex-wrap:wrap">
      <span :if={@counts.undone > 0} style="color:var(--sc-dead-fg)">{@counts.undone} undone</span>
      <span :if={@counts.succeeded > 0} style="color:var(--sc-ok-fg)">{@counts.succeeded} ✓</span>
      <span :if={@counts.failed > 0} style="color:var(--sc-err-fg)">{@counts.failed} ✕</span>
      <span :if={@counts.pending > 0} style="color:var(--sc-ink-3)">{@counts.pending} pending</span>
      <span :if={@counts.total == 0} style="color:var(--sc-ink-3)">no steps</span>
    </span>
    """
  end

  defp ranges, do: @ranges

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp no_filters?(f) do
    is_nil(f.status) and is_nil(f.resource) and is_nil(f.resource_id) and
      not f.has_errors and f.query in [nil, ""]
  end

  defp empty_title(f) do
    if no_filters?(f), do: "No sagas yet", else: "Nothing matches these filters"
  end
end
