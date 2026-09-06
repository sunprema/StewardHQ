defmodule StewardWeb.Console.SagaLive do
  @moduledoc """
  Saga detail (docs/ux_requirements.md §6.2 "content, saga detail", design
  artboard 1c).

  Shows the plan as originally submitted, then the steps in execution
  order. Compensation is separated out and rendered in reverse, because
  that is the order it actually ran — §6.2 asks for the undo order to read
  distinctly rather than being mixed into the forward list.

  Read-only: retries are scheduled by `AshOban` against
  `Steward.Sagas.Saga`'s `:retry` trigger, never from this screen
  (§4 principle 1).
  """

  use StewardWeb, :live_view

  import StewardWeb.Console.Components

  alias Steward.Console.Activity
  alias StewardWeb.Console.Layout

  on_mount {StewardWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Activity.get_saga(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That saga does not exist.")
         |> push_navigate(to: ~p"/console/sagas")}

      saga ->
        {:ok,
         assign(socket,
           saga: saga,
           forward: Enum.reject(saga.steps_ordered, &(&1.status == :undone)),
           undone: Enum.filter(saga.steps_ordered, &(&1.status == :undone)),
           plan_open: false,
           live_state: :live,
           query: "",
           last_fresh_at: DateTime.utc_now(),
           page_title: "Saga #{truncate_id(saga.id)} · StewardHQ"
         )}
    end
  end

  @impl true
  def handle_event("toggle-plan", _params, socket) do
    {:noreply, assign(socket, plan_open: not socket.assigns.plan_open)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, query: q)}
  end

  def handle_event("search-submit", %{"q" => q}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/console/sagas?q=#{q}")}
  end

  def handle_event("toggle-live", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layout.shell
      page={:sagas}
      persona="Agent developer"
      query={@query}
      live_state={@live_state}
      last_fresh_at={@last_fresh_at}
    >
      <nav class="sc-crumb">
        <.link navigate={~p"/console/sagas"}>Sagas</.link>
        <span aria-hidden="true">›</span>
        <span class="sc-mono">{truncate_id(@saga.id)}</span>
      </nav>

      <div class="sc-card">
        <div style="padding:16px 20px;display:flex;flex-direction:column;gap:14px">
          <div>
            <h1 style="margin:0;font-size:18px;font-weight:600">
              {title(@saga)}
            </h1>
            <div style="margin-top:5px;font-size:12px;color:var(--sc-ink-3)">
              Saga <.id value={to_string(@saga.id)} head={8} tail={4} /> · run by
              <span class="sc-mono" style="color:var(--sc-ink-2)">{@saga.tool}</span>
              · plan of {length(@saga.plan || [])} step{plural(length(@saga.plan || []))} on
              {length(@saga.resources)} resource{plural(length(@saga.resources))}
            </div>
          </div>

          <dl class="sc-defs" style="grid-template-columns:repeat(4,minmax(0,max-content))">
            <div>
              <dt>Status</dt>
              <dd><.chip status={@saga.status} /></dd>
            </div>
            <div>
              <dt>Attempts</dt>
              <dd class="sc-mono">
                {@saga.attempts} / 5
                <span :if={@saga.status == :failed} style="color:var(--sc-ink-3)">· retry queued</span>
                <span :if={@saga.status == :dead_letter} style="color:var(--sc-dead-fg)">
                  · retries stopped
                </span>
              </dd>
            </div>
            <div>
              <dt>Started</dt>
              <dd><.time at={@saga.inserted_at} /></dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd class="sc-mono">
                {if @saga.status == :running, do: "—", else: duration_ms(@saga.duration_ms)}
              </dd>
            </div>
          </dl>

          <div
            :if={@saga.status == :dead_letter}
            class="sc-gap"
            style="border-style:solid;border-color:var(--sc-dead-bg)"
          >
            <b>Dead-letter.</b>
            This saga reached the retry ceiling and will not be retried again. It is
            kept for diagnosis; a human decides what happens next.
          </div>
        </div>
      </div>

      <div class="sc-card">
        <button
          type="button"
          phx-click="toggle-plan"
          class="sc-card-head"
          style="width:100%;background:none;border:0;border-bottom:1px solid var(--sc-border-soft);cursor:pointer;font-family:inherit;text-align:left"
          aria-expanded={to_string(@plan_open)}
        >
          <span aria-hidden="true">{if @plan_open, do: "▾", else: "▸"}</span>
          <span class="sc-card-title">Plan as submitted</span>
          <span class="sc-card-meta">{plan_summary(@saga)}</span>
        </button>

        <div :if={@plan_open} style="padding:12px 16px">
          <pre class="sc-payload">{format_payload(@saga.plan)}</pre>
        </div>
      </div>

      <div class="sc-card">
        <div class="sc-card-head">
          <span class="sc-card-title">Steps · execution order</span>
          <span class="sc-card-meta">{length(@forward)} step{plural(length(@forward))}</span>
        </div>

        <.empty :if={@saga.steps_ordered == []} title="No steps recorded">
          The saga row exists but no step has been written yet.
        </.empty>

        <.step_row
          :for={{step, index} <- Enum.with_index(@forward, 1)}
          step={step}
          index={index}
          saga_id={@saga.id}
        />
      </div>

      <div :if={@undone != []} class="sc-card">
        <div class="sc-card-head">
          <span class="sc-card-title">Undo · compensation ran in reverse</span>
          <span class="sc-card-meta">
            {length(@undone)} step{plural(length(@undone))} undone after the failure,
            before the borrow was released
          </span>
        </div>

        <.step_row
          :for={{step, index} <- Enum.with_index(@undone, 1)}
          step={step}
          index={index}
          saga_id={@saga.id}
          undo={true}
        />
      </div>

      <div style="display:flex;gap:18px;align-items:center;flex-wrap:wrap">
        <.link navigate={~p"/console/agents?agent=#{@saga.tool}"} class="sc-link">
          Agent tree · {@saga.tool} ›
        </.link>
        <.link :for={r <- resource_ids(@saga)} navigate={~p"/console/borrows?q=#{r}"} class="sc-link">
          Borrow history · {r} ›
        </.link>
        <span style="margin-left:auto;font-size:11px;color:var(--sc-ink-3)">
          Read-only. Retries are scheduled by the runtime, not from here.
        </span>
      </div>
    </Layout.shell>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :saga_id, :any, required: true
  attr :undo, :boolean, default: false

  defp step_row(assigns) do
    assigns = assign(assigns, :reason, Activity.reason_of(assigns.step))

    ~H"""
    <div class="sc-step" data-status={@step.status}>
      <span class="sc-step-n">{if @undo, do: "↶#{@index}", else: @index}</span>

      <div style="min-width:0">
        <div>
          <span style="font-weight:600">{@step.action}</span>
          <span style="color:var(--sc-ink-3)">
            {if @undo, do: "undo ·", else: "on"} {Activity.short_resource(@step.resource)}
          </span>
          <span class="sc-mono" style="font-size:12px;color:var(--sc-ink-2)">
            {@step.resource_id}
          </span>
        </div>
        <div class="sc-step-note">
          step <span class="sc-mono">{truncate_id(@step.step_id, 6, 2)}</span>
          <.link
            :if={@step.status == :failed}
            navigate={~p"/console/sagas/#{@saga_id}/steps/#{@step.step_id}"}
            class="sc-link"
          >
            · Step detail ›
          </.link>
        </div>

        <div :if={@reason} class="sc-step-err">
          <.error_reason reason={@reason} />
          <div :if={disposition_rule(@step.disposition)} class="sc-step-note" style="margin-top:6px">
            {disposition_rule(@step.disposition)}
          </div>
        </div>
      </div>

      <span><.chip status={@step.status} /></span>
      <span>
        <.chip :if={@step.disposition} status={@step.disposition} />
        <span :if={is_nil(@step.disposition)} style="color:var(--sc-ink-3);font-size:12px">—</span>
      </span>
      <span class="sc-time">{step_duration(@step)}</span>
    </div>
    """
  end

  # The disposition rule is documented in Steward.Sagas.StepRunner: it is a
  # function of the error taxonomy, not a per-step decision.
  defp disposition_rule(:survived),
    do: "Capability survived — stale_resource resyncs and retries, so the right is still needed."

  defp disposition_rule(:dropped),
    do:
      "Capability dropped — the plan can never succeed from this state, so the right is surrendered and a fresh borrow is required."

  defp disposition_rule(:consumed),
    do: "Capability consumed — linear, used exactly once."

  defp disposition_rule(_), do: nil

  defp step_duration(%{inserted_at: start, updated_at: finish})
       when not is_nil(start) and not is_nil(finish) do
    case DateTime.diff(finish, start, :millisecond) do
      0 -> "—"
      ms -> duration_ms(ms)
    end
  end

  defp step_duration(_), do: "—"

  defp title(saga) do
    action = saga.tool || "Saga"
    label = action |> to_string() |> String.replace("_", " ") |> String.capitalize()

    case resource_ids(saga) do
      [] -> label
      [one | _] -> "#{label} · #{one}"
    end
  end

  defp resource_ids(saga) do
    saga.steps_ordered |> Enum.map(& &1.resource_id) |> Enum.uniq()
  end

  defp plan_summary(saga) do
    steps = saga.plan || []

    actions =
      steps
      |> Enum.map(fn step -> Map.get(step, "action") || Map.get(step, :action) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" → ")

    if actions == "", do: "#{length(steps)} steps", else: actions
  end

  # Structured rendering of a stored jsonb payload, rather than raw JSON —
  # §6.2 asks for structured by default with raw available.
  defp format_payload(nil), do: "—"

  defp format_payload(value) do
    value |> inspect(pretty: true, limit: :infinity, width: 76) |> to_string()
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
