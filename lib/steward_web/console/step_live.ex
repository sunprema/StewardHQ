defmodule StewardWeb.Console.StepLive do
  @moduledoc """
  Step detail (docs/ux_requirements.md §6.2 "content, step detail", design
  artboard 1d).

  The deepest investigative view: the full result or error payload, the
  capability used and why it was disposed of the way it was, and the borrow
  and lease in force when the step ran.

  ## What is real and what is not

  `Steward.Sagas.StepRunner` persists the action, resource, resource id,
  status, disposition, and either `result` or `%{reason: inspect(reason)}`.
  All of that is rendered from the row.

  The borrow ref, fencing token and lease expiry at execution time are
  **not** persisted — `agent_interaction_ux.md` lists holder identity and
  per-waiter detail as gaps, and nothing writes the lease token onto the
  step. Rather than invent those values, this screen names the gap. The
  design draws them because the design is of the finished system.
  """

  use StewardWeb, :live_view

  import StewardWeb.Console.Components

  alias Steward.Console.Activity
  alias StewardWeb.Console.Layout

  on_mount {StewardWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => saga_id, "step_id" => step_id}, _session, socket) do
    with saga when not is_nil(saga) <- Activity.get_saga(saga_id),
         step when not is_nil(step) <- Enum.find(saga.steps_ordered, &(&1.step_id == step_id)) do
      index = Enum.find_index(saga.steps_ordered, &(&1.step_id == step_id)) + 1

      {:ok,
       assign(socket,
         saga: saga,
         step: step,
         index: index,
         reason: Activity.reason_of(step),
         payload_view: :structured,
         live_state: :live,
         query: "",
         last_fresh_at: DateTime.utc_now(),
         page_title: "Step #{step_id} · StewardHQ"
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That step does not exist.")
         |> push_navigate(to: ~p"/console/sagas/#{saga_id}")}
    end
  end

  @impl true
  def handle_event("payload-view", %{"view" => view}, socket) do
    {:noreply, assign(socket, payload_view: String.to_existing_atom(view))}
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
        <.link navigate={~p"/console/sagas/#{@saga.id}"}>{truncate_id(@saga.id)}</.link>
        <span aria-hidden="true">›</span>
        <span>step {@index}</span>
      </nav>

      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span class="sc-step-n">{@index}</span>
        <h1 style="margin:0;font-size:18px;font-weight:600">{@step.action}</h1>
        <span style="color:var(--sc-ink-3);font-size:13px">
          on {Activity.short_resource(@step.resource)}
        </span>
        <span class="sc-mono" style="font-size:13px">{@step.resource_id}</span>
        <.chip status={@step.status} />
        <span style="font-size:11.5px;color:var(--sc-ink-3)">
          step <.id value={@step.step_id} head={6} tail={4} /> · ran
          <.time at={@step.inserted_at} /> at {absolute(@step.inserted_at)}
        </span>
      </div>

      <div style="display:grid;grid-template-columns:minmax(0,1.35fr) minmax(0,1fr);gap:14px;align-items:start">
        <div style="display:flex;flex-direction:column;gap:14px;min-width:0">
          <div class="sc-card">
            <div class="sc-card-head">
              <span class="sc-card-title">{if @reason, do: "Error", else: "Result"}</span>
              <div class="sc-tabs" role="tablist">
                <button
                  :for={{view, label} <- [structured: "Structured", raw: "Raw"]}
                  type="button"
                  role="tab"
                  class="sc-tab"
                  aria-selected={to_string(@payload_view == view)}
                  phx-click="payload-view"
                  phx-value-view={view}
                >
                  {label}
                </button>
              </div>
            </div>

            <div style="padding:14px 16px;display:flex;flex-direction:column;gap:12px">
              <.error_reason :if={@reason} reason={@reason} />

              <div :if={@payload_view == :structured}>
                <.payload_fields payload={payload(@step)} />
              </div>

              <pre :if={@payload_view == :raw} class="sc-payload">{inspect(payload(@step), pretty: true, limit: :infinity, width: 72)}</pre>

              <div :if={@reason} class="sc-gap">
                <b>Retry policy.</b>
                {retry_policy(@reason)}
              </div>

              <span :if={@reason} class="sc-link" title="Errors screen is designed but not built yet" style="opacity:.5">
                Errors screen · filtered to {@reason} ›
              </span>
            </div>
          </div>

          <div class="sc-card">
            <div class="sc-card-head"><span class="sc-card-title">Arguments</span></div>
            <div style="padding:14px 16px">
              <.payload_fields payload={plan_args(@saga, @step)} empty="No arguments recorded for this step." />
            </div>
          </div>
        </div>

        <div style="display:flex;flex-direction:column;gap:14px;min-width:0">
          <div class="sc-card">
            <div class="sc-card-head">
              <span class="sc-card-title">Capability used</span>
              <span style="margin-left:auto">
                <.chip :if={@step.disposition} status={@step.disposition} />
                <span :if={is_nil(@step.disposition)} style="font-size:11px;color:var(--sc-ink-3)">
                  not applicable
                </span>
              </span>
            </div>
            <div style="padding:14px 16px;display:flex;flex-direction:column;gap:10px">
              <p style="margin:0;font-size:12px;color:var(--sc-ink-2)">
                {disposition_explanation(@step.disposition)}
              </p>
              <div class="sc-gap">
                <b>Capability ref not recorded.</b>
                The runtime issues a capability per step, but the step row does not
                store its ref — <span class="sc-mono">Steward.CapabilityRegistry</span>
                exposes only <span class="sc-mono">status/1</span> for a single ref and has
                no list function yet (agent_interaction_ux.md, gap 3).
              </div>
            </div>
          </div>

          <div class="sc-card">
            <div class="sc-card-head">
              <span class="sc-card-title">Borrow &amp; lease at execution</span>
            </div>
            <div style="padding:14px 16px">
              <div class="sc-gap">
                <b>Not recorded yet.</b>
                Mode, borrow ref, fencing token and lease expiry are in-memory state at
                execution time and are not written to the step row.
                <span class="sc-mono">Steward.ResourceServer.borrows/1</span>
                omits holder pids and queue waiters (gap 4), and no telemetry event
                captures the lease token per step. This panel fills in once that
                instrumentation lands.
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layout.shell>
    """
  end

  attr :payload, :any, required: true
  attr :empty, :string, default: "Nothing recorded."

  defp payload_fields(assigns) do
    ~H"""
    <dl :if={is_map(@payload) and map_size(@payload) > 0} class="sc-defs">
      <div :for={{key, value} <- Enum.sort_by(@payload, &elem(&1, 0))}>
        <dt>{key |> to_string() |> String.replace("_", " ")}</dt>
        <dd class="sc-mono">{render_value(value)}</dd>
      </div>
    </dl>
    <p
      :if={not (is_map(@payload) and map_size(@payload) > 0)}
      style="margin:0;font-size:12px;color:var(--sc-ink-3)"
    >
      {@empty}
    </p>
    """
  end

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value) when is_number(value), do: to_string(value)
  defp render_value(value) when is_boolean(value), do: to_string(value)
  defp render_value(value), do: inspect(value, limit: 8)

  defp payload(%{status: :failed, error: error}) when is_map(error), do: error
  defp payload(%{result: result}) when is_map(result), do: result
  defp payload(_), do: %{}

  # Arguments live on the plan step, not the saga step row.
  defp plan_args(saga, step) do
    (saga.plan || [])
    |> Enum.find(fn plan_step ->
      (Map.get(plan_step, "id") || Map.get(plan_step, :id)) == step.step_id
    end)
    |> case do
      nil -> %{}
      plan_step -> Map.get(plan_step, "args") || Map.get(plan_step, :args) || %{}
    end
  end

  defp retry_policy("stale_resource"),
    do:
      "Retried. The backend moved underneath the agent, so the runtime resyncs the shadow record and runs the step again; the capability survives for that retry."

  defp retry_policy(_),
    do:
      "Not retried. Only stale_resource is retried; this failure unwinds and compensation runs in reverse."

  defp disposition_explanation(:consumed),
    do: "Linear: the capability was used exactly once and is now gone."

  defp disposition_explanation(:survived),
    do:
      "The capability survived the failure. Rule: stale_resource resyncs and retries, so the right is still needed."

  defp disposition_explanation(:dropped),
    do:
      "The capability was dropped. Rule: the plan can never succeed from this state, so the right is surrendered and a fresh borrow and re-observation are required upstream."

  defp disposition_explanation(_),
    do:
      "No disposition recorded — the step either has not finished or succeeded with a reusable capability."
end
