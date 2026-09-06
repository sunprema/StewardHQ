defmodule StewardWeb.Console.Components do
  @moduledoc """
  Shared presentation components for the StewardHQ console
  (docs/ux_requirements.md §9 deliverable 2: status chip, identifier with
  copy, live indicator, time display, error reason with subtitle, tree node,
  countdown).

  Two rules from §4 are enforced here rather than left to each screen:

    * **Never colour alone.** `chip/1` always renders a glyph beside the
      label, so status survives greyscale and colour-blindness (§7
      accessibility).
    * **Read-only by construction.** Nothing in this module emits a control
      that mutates runtime state (§4 principle 1).
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ------------------------------------------------------------------
  # Status vocabulary
  # ------------------------------------------------------------------

  # {tone, glyph, label} for every status word in ux_requirements.md §3.
  # Tones map onto the six-way semantic palette in §4 principle 7.
  @statuses %{
    # saga
    running: {"run", "●", "Running"},
    completed: {"ok", "✓", "Completed"},
    failed: {"err", "✕", "Failed"},
    dead_letter: {"dead", "■", "Dead-letter"},
    # step
    pending: {"neutral", "○", "Pending"},
    succeeded: {"ok", "✓", "Succeeded"},
    undone: {"dead", "↶", "Undone"},
    # capability
    active: {"ok", "✓", "active"},
    moved: {"share", "→", "moved"},
    consumed: {"share", "◈", "consumed"},
    expired: {"dead", "■", "expired"},
    dropped: {"dead", "■", "dropped"},
    # disposition
    survived: {"share", "◈", "survived"},
    # borrow mode
    exclusive: {"run", "◆", "exclusive"},
    shared: {"share", "◇", "shared"},
    # sync state
    synced: {"ok", "✓", "synced"},
    stale: {"warn", "▲", "stale"},
    conflicted: {"err", "✕", "Conflicted"},
    # attention kinds
    expiring: {"warn", "▲", "Expiring"},
    queue: {"warn", "◷", "Queue"},
    # agent liveness
    alive: {"ok", "✓", "alive"},
    exited: {"dead", "■", "exited"}
  }

  @doc "Tone, glyph and default label for a status atom."
  def status_meta(status) when is_atom(status) do
    Map.get(@statuses, status, {"neutral", "•", status |> to_string() |> humanize()})
  end

  def status_meta(status) when is_binary(status) do
    status |> String.to_existing_atom() |> status_meta()
  rescue
    ArgumentError -> {"neutral", "•", humanize(status)}
  end

  defp humanize(s), do: s |> to_string() |> String.replace("_", " ")

  # ------------------------------------------------------------------
  # Error taxonomy
  # ------------------------------------------------------------------

  # Fixed reasons from ux_requirements.md §3. The reason itself is never
  # reworded; the subtitle is the plain-language gloss shown beside it.
  @error_subtitles %{
    "unborrowed_access" => "Tried to touch a resource without borrowing it first",
    "unfenced_write" => "Tried to write without a lease token",
    "lease_expired" => "Held the resource too long; the lease ran out",
    "stale_resource" => "The backend changed underneath the agent; needs a resync",
    "invalid_transition" => "Asked for a state change the resource does not allow",
    "capability_moved" => "Tried to reuse a capability already handed to another agent",
    "irreversible_before_fallible" =>
      "Plan puts an irreversible step before one that can fail"
  }

  @doc "Plain-language subtitle for a fixed error reason, or nil."
  def error_subtitle(reason) when is_atom(reason), do: error_subtitle(to_string(reason))
  def error_subtitle(reason) when is_binary(reason), do: Map.get(@error_subtitles, reason)
  def error_subtitle(_), do: nil

  @doc "Every known error reason, for filter menus."
  def error_reasons, do: Map.keys(@error_subtitles)

  # ------------------------------------------------------------------
  # Chip
  # ------------------------------------------------------------------

  @doc """
  Status chip: pastel background, semantic foreground, and always a glyph.

      <.chip status={:failed} />
      <.chip status={:shared} label="shared ×3" />
      <.chip tone="warn" glyph="▲" label="expires 12 s" />
  """
  attr :status, :any, default: nil
  attr :tone, :string, default: nil
  attr :glyph, :string, default: nil
  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def chip(assigns) do
    {tone, glyph, label} =
      case assigns.status do
        nil -> {assigns.tone || "neutral", assigns.glyph, assigns.label}
        status -> status_meta(status)
      end

    assigns =
      assigns
      |> assign(:tone, assigns.tone || tone)
      |> assign(:glyph, assigns.glyph || glyph)
      |> assign(:label, assigns.label || label)

    ~H"""
    <span class={["sc-chip", @class]} data-tone={@tone} {@rest}>
      <span :if={@glyph} class="sc-chip-glyph" aria-hidden="true">{@glyph}</span>{@label}
    </span>
    """
  end

  # ------------------------------------------------------------------
  # Identifier with copy
  # ------------------------------------------------------------------

  @doc """
  Opaque identifier, truncated to a fixed width with the full value in a
  tooltip and a copy affordance (§4 principle 5, §7 identifiers).
  """
  attr :value, :string, required: true
  attr :prefix, :string, default: nil
  attr :head, :integer, default: 4
  attr :tail, :integer, default: 4
  attr :copy, :boolean, default: true
  attr :class, :string, default: nil

  def id(assigns) do
    assigns = assign(assigns, :short, truncate_id(assigns.value, assigns.head, assigns.tail))

    ~H"""
    <span class={["sc-id", @class]} title={@value}>
      <span>{@prefix}{@short}</span>
      <button
        :if={@copy}
        type="button"
        class="sc-id-copy"
        aria-label={"Copy #{@value}"}
        phx-click={JS.dispatch("steward:copy", detail: %{text: @value})}
      >
        ⧉
      </button>
    </span>
    """
  end

  @doc """
  Truncate an opaque id to `head…tail`, consistently across every screen.
  Ids already short enough are returned untouched.
  """
  def truncate_id(value, head \\ 4, tail \\ 4)
  def truncate_id(nil, _head, _tail), do: ""

  def truncate_id(value, head, tail) when is_binary(value) do
    if String.length(value) <= head + tail + 1 do
      value
    else
      String.slice(value, 0, head) <> "…" <> String.slice(value, -tail, tail)
    end
  end

  def truncate_id(value, head, tail), do: value |> to_string() |> truncate_id(head, tail)

  # ------------------------------------------------------------------
  # Live indicator
  # ------------------------------------------------------------------

  @doc """
  Connected / paused / disconnected indicator (§7). Clicking toggles pause,
  which only stops the screen refreshing — it changes no runtime state.
  """
  attr :state, :atom, values: [:live, :paused, :disconnected], default: :live
  attr :last_fresh_at, :any, default: nil
  attr :rest, :global

  def live_indicator(assigns) do
    ~H"""
    <button
      type="button"
      class="sc-live"
      data-state={@state}
      phx-click="toggle-live"
      title={live_title(@state, @last_fresh_at)}
      {@rest}
    >
      <span class="sc-live-dot" aria-hidden="true"></span>
      {live_label(@state)}
    </button>
    """
  end

  defp live_label(:live), do: "Live"
  defp live_label(:paused), do: "Paused"
  defp live_label(:disconnected), do: "Disconnected"

  defp live_title(:live, _), do: "Updating in place. Click to pause."
  defp live_title(:paused, _), do: "Updates paused. Click to resume."

  defp live_title(:disconnected, nil), do: "Disconnected — showing the last data received."

  defp live_title(:disconnected, at),
    do: "Disconnected — last fresh at #{absolute(at)}."

  # ------------------------------------------------------------------
  # Time
  # ------------------------------------------------------------------

  @doc """
  Relative time by default, absolute on hover (§4 principle 4, §7).
  `tone` lets a caller mark an urgent countdown amber.
  """
  attr :at, :any, default: nil
  attr :seconds, :any, default: nil
  attr :suffix, :string, default: nil
  attr :tone, :string, default: nil
  attr :class, :string, default: nil

  def time(assigns) do
    assigns =
      assign(assigns, :text, time_text(assigns.at, assigns.seconds, assigns.suffix))

    ~H"""
    <span class={["sc-time", @class]} data-tone={@tone} title={@at && absolute(@at)}>
      {@text}
    </span>
    """
  end

  defp time_text(_at, seconds, suffix) when is_integer(seconds) do
    [suffix, duration(seconds)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp time_text(nil, _seconds, _suffix), do: "—"

  defp time_text(at, _seconds, suffix) do
    [relative(at), suffix] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  @doc """
  Compact duration: `12 s`, `4 m 10 s`, `2 h 14 m`. Matches the mockups,
  which use a space between number and unit.
  """
  def duration(nil), do: "—"
  def duration(seconds) when seconds < 0, do: "0 s"
  def duration(seconds) when seconds < 60, do: "#{seconds} s"

  def duration(seconds) when seconds < 3600 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    if s == 0, do: "#{m} m", else: "#{m} m #{s} s"
  end

  def duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if m == 0, do: "#{h} h", else: "#{h} h #{m} m"
  end

  @doc "Milliseconds as a duration, keeping sub-second precision readable."
  def duration_ms(nil), do: "—"
  def duration_ms(ms) when ms < 1000, do: "#{ms} ms"
  def duration_ms(ms) when ms < 10_000, do: "#{Float.round(ms / 1000, 1)} s"
  def duration_ms(ms), do: duration(div(ms, 1000))

  @doc "Relative time against now, e.g. `3 m ago`, `in 12 s`."
  def relative(nil), do: "—"

  def relative(%DateTime{} = at) do
    diff = DateTime.diff(at, DateTime.utc_now())

    cond do
      diff > 0 -> "in " <> duration(diff)
      true -> duration(-diff) <> " ago"
    end
  end

  @doc "Absolute time, in the single timezone the console displays (UTC)."
  def absolute(nil), do: "—"

  def absolute(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  # ------------------------------------------------------------------
  # Error reason
  # ------------------------------------------------------------------

  @doc """
  A fixed error reason in monospace with its plain-language subtitle.
  The reason is never reworded (§3).
  """
  attr :reason, :any, required: true
  attr :subtitle, :boolean, default: true
  attr :class, :string, default: nil

  def error_reason(assigns) do
    assigns = assign(assigns, :text, assigns.reason && to_string(assigns.reason))

    ~H"""
    <span class={["inline-flex items-baseline gap-2 flex-wrap", @class]}>
      <span class="sc-mono" style="font-size:12px;font-weight:500;color:var(--sc-err-fg)">
        {@text}
      </span>
      <span
        :if={@subtitle && error_subtitle(@text)}
        style="font-size:11.5px;color:var(--sc-ink-3)"
      >
        {error_subtitle(@text)}
      </span>
    </span>
    """
  end

  # ------------------------------------------------------------------
  # Stat tile
  # ------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: nil
  attr :navigate, :string, default: nil
  slot :foot

  def tile(%{navigate: nil} = assigns) do
    ~H"""
    <div class="sc-tile">
      <div class="sc-tile-label">{@label}</div>
      <div class="sc-tile-value" data-tone={@tone}>{@value}</div>
      {render_slot(@foot)}
    </div>
    """
  end

  def tile(assigns) do
    ~H"""
    <.link navigate={@navigate} class="sc-tile" title="Open the rows behind this count">
      <div class="sc-tile-label">{@label}</div>
      <div class="sc-tile-value" data-tone={@tone}>{@value}</div>
      {render_slot(@foot)}
    </.link>
    """
  end

  # ------------------------------------------------------------------
  # Empty state
  # ------------------------------------------------------------------

  @doc """
  Empty state. `kind: :no_live_state` is the one required by §4 principle 2:
  in-memory state vanishes on restart, so an empty live screen must say so
  and name the runtime start time rather than look like nothing happened.
  """
  attr :kind, :atom, default: :empty
  attr :title, :string, default: nil
  attr :started_at, :any, default: nil
  slot :inner_block

  def empty(assigns) do
    ~H"""
    <div class="sc-empty">
      <b>{@title || default_empty_title(@kind)}</b>
      <span :if={@kind == :no_live_state}>
        Borrows, leases, capabilities and agents live in memory only and do not
        survive a restart. The runtime started
        <span class="sc-mono">{relative(@started_at)}</span>.
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp default_empty_title(:no_live_state), do: "No live state"
  defp default_empty_title(:healthy), do: "Nothing needs attention"
  defp default_empty_title(_), do: "Nothing to show"
end
