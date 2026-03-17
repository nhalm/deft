defmodule Deft.OM.State do
  @moduledoc """
  State for the Observational Memory system.

  This struct holds all the data for the OM system:
  - Active observations that are injected into every turn
  - Buffered chunks from pre-computed observation cycles
  - Metadata about what messages have been observed
  - Flags for in-flight observation/reflection cycles
  - Token counts and calibration data
  """

  alias Deft.OM.BufferedChunk

  @type t :: %__MODULE__{
          active_observations: String.t(),
          observation_tokens: integer(),
          buffered_chunks: [BufferedChunk.t()],
          buffered_reflection: String.t() | nil,
          last_observed_at: DateTime.t() | nil,
          observed_message_ids: [String.t()],
          pending_message_tokens: integer(),
          generation_count: integer(),
          is_observing: boolean(),
          is_reflecting: boolean(),
          needs_rebuffer: boolean(),
          activation_epoch: integer(),
          snapshot_dirty: boolean(),
          calibration_factor: float(),
          sync_from: GenServer.from() | nil
        }

  @enforce_keys []
  defstruct active_observations: "",
            observation_tokens: 0,
            buffered_chunks: [],
            buffered_reflection: nil,
            last_observed_at: nil,
            observed_message_ids: [],
            pending_message_tokens: 0,
            generation_count: 0,
            is_observing: false,
            is_reflecting: false,
            needs_rebuffer: false,
            activation_epoch: 0,
            snapshot_dirty: false,
            calibration_factor: 4.0,
            sync_from: nil
end
