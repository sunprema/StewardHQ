defmodule Steward.Sagas do
  @moduledoc """
  Domain for durable saga state (docs/tech_spec.md §4.3, §8 Phase 4).
  """

  use Ash.Domain,
    otp_app: :steward

  resources do
    resource Steward.Sagas.Saga do
      define :create_saga, action: :create, args: [:plan]
      define :complete_saga, action: :complete
      define :fail_saga, action: :fail, args: [:error]
      define :escalate_saga, action: :escalate, args: [:error]
      define :retry_saga, action: :retry
      define :get_saga, action: :read, get_by: [:id]
      define :list_sagas, action: :read
    end

    resource Steward.Sagas.SagaStep do
      define :create_saga_step,
        action: :create,
        args: [:saga_id, :step_id, :resource, :resource_id, :action]

      define :succeed_saga_step, action: :succeed, args: [:result, :disposition]
      define :fail_saga_step, action: :fail, args: [:error, :disposition]
      define :undo_saga_step, action: :undo
    end
  end
end
