defmodule StewardWeb.Console.Layout do
  @moduledoc """
  The console shell: sidebar navigation, search, live indicator and persona
  stamp (docs/ux_requirements.md §5 "global elements on every screen").

  The sidebar mirrors the information architecture in §5 exactly, including
  the Consistency and Tools sections. Screens not yet built are rendered as
  disabled items rather than omitted, so the IA reads whole.
  """

  use Phoenix.Component

  import StewardWeb.Console.Components

  alias Steward.Console.LiveState

  attr :page, :atom, required: true
  attr :persona, :string, required: true
  attr :counts, :map, default: %{}
  attr :live_state, :atom, default: :live
  attr :last_fresh_at, :any, default: nil
  attr :query, :string, default: ""
  attr :env, :string, default: "dev"
  attr :started_at, :any, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="sc-root">
      <aside class="sc-side">
        <div class="sc-brandbar">
          <div class="sc-logo" aria-hidden="true">S</div>
          <span class="sc-wordmark">StewardHQ</span>
          <span class="sc-env" title={"Environment: #{@env}"}>{@env}</span>
        </div>

        <.nav_item page={@page} id={:overview} label="Overview" navigate="/console" />

        <div class="sc-navgroup">Activity</div>
        <.nav_item page={@page} id={:sagas} label="Sagas" navigate="/console/sagas" />

        <div class="sc-navgroup">Live</div>
        <.nav_item
          page={@page}
          id={:borrows}
          label="Borrow board"
          navigate="/console/borrows"
          count={@counts[:borrows]}
          tone={@counts[:borrows_tone]}
        />
        <.nav_item page={@page} id={:capabilities} label="Capabilities" count={@counts[:capabilities]} />
        <.nav_item
          page={@page}
          id={:agents}
          label="Agents"
          navigate="/console/agents"
          count={@counts[:agents]}
        />

        <div class="sc-navgroup">Consistency</div>
        <.nav_item page={@page} id={:shadows} label="Shadow records" />

        <div class="sc-navgroup">&nbsp;</div>
        <.nav_item page={@page} id={:errors} label="Errors" count={@counts[:errors]} tone="err" />

        <div class="sc-navgroup">Tools</div>
        <.nav_item page={@page} id={:validator} label="Plan validator" />

        <div class="sc-side-foot">
          Runtime started<br />
          <span>{relative(@started_at || LiveState.started_at())}</span> · times in UTC
        </div>
      </aside>

      <div class="sc-main">
        <header class="sc-topbar">
          <form class="sc-search" phx-change="search" phx-submit="search-submit" role="search">
            <span aria-hidden="true">⌕</span>
            <input
              type="search"
              name="q"
              value={@query}
              autocomplete="off"
              placeholder="Search resource id, saga id or agent name"
              aria-label="Search resource id, saga id or agent name"
            />
            <span class="sc-kbd" aria-hidden="true">/</span>
          </form>

          <.live_indicator state={@live_state} last_fresh_at={@last_fresh_at} />

          <div class="sc-persona">
            Persona · <b>{@persona}</b>
          </div>
        </header>

        <div class={["sc-page", @live_state == :disconnected && "sc-stale"]}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # A nav item without a `navigate` is a screen the console does not serve
  # yet. It stays visible so the IA in §5 reads whole, but is inert and
  # announced as unavailable rather than looking like a dead link.
  attr :page, :atom, required: true
  attr :id, :atom, required: true
  attr :label, :string, required: true
  attr :navigate, :string, default: nil
  attr :count, :any, default: nil
  attr :tone, :string, default: nil

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <div
      class="sc-nav"
      style="opacity:.5;cursor:default"
      title={"#{@label} — designed, not built yet"}
      aria-disabled="true"
    >
      {@label}
      <span :if={@count} class="sc-nav-count" data-tone={@tone}>{@count}</span>
    </div>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="sc-nav"
      aria-current={@page == @id && "page"}
    >
      {@label}
      <span :if={@count} class="sc-nav-count" data-tone={@tone}>{@count}</span>
    </.link>
    """
  end
end
