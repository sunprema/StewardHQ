defmodule Steward.Sagas.PlanCodec do
  @moduledoc """
  Converts a `Steward.SagaExecutor` plan (a list of `Steward.PlanValidator.step/0`
  maps, with atom keys, module resources, and `DateTime` timestamps) to and
  from the JSON-safe shape `Steward.Sagas.Saga`'s `:plan` attribute stores
  (docs/tech_spec.md §4.3 "durable saga state").

  Only what the codebase's own plans actually use is handled: `:resource`
  (a loaded module — modules *are* atoms in Elixir, so `to_string/1` and
  `String.to_existing_atom/1` round-trip it losslessly without ever
  minting a new atom from external input, unlike `String.to_atom/1`),
  `:action` (same trick), and `:observed_at` (ISO 8601). Everything else
  (`:id`, `:resource_id`, `:args`, `:undo_args`, `:compensate_args`) is
  passed through as-is: it must already be JSON-safe, since Oban's job
  args (the persistent retry queue) face the identical constraint.
  """

  @doc "Encodes a plan into the JSON-safe shape stored on `Steward.Sagas.Saga.plan`."
  @spec encode([map()]) :: [map()]
  def encode(steps), do: Enum.map(steps, &encode_step/1)

  @doc "Decodes a plan previously produced by `encode/1` back into `Steward.PlanValidator.step/0` maps."
  @spec decode([map()]) :: [map()]
  def decode(steps), do: Enum.map(steps, &decode_step/1)

  defp encode_step(step) do
    step
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update!("resource", &to_string/1)
    |> Map.update!("action", &to_string/1)
    |> Map.update("observed_at", nil, &encode_datetime/1)
  end

  defp decode_step(step) do
    step
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Map.update!(:resource, &String.to_existing_atom/1)
    |> Map.update!(:action, &String.to_existing_atom/1)
    |> Map.update(:observed_at, nil, &decode_datetime/1)
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp decode_datetime(nil), do: nil

  defp decode_datetime(iso8601) when is_binary(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    datetime
  end
end
