defmodule Deft.OM.BufferedChunk do
  @moduledoc """
  A buffered observation chunk produced by the Observer.

  Buffered chunks are pre-computed observations that haven't been activated yet.
  They carry an epoch to detect staleness - if the activation_epoch has changed
  since the chunk was created, the chunk is discarded.
  """

  @type t :: %__MODULE__{
          observations: String.t(),
          token_count: integer(),
          message_ids: [String.t()],
          message_tokens: integer(),
          epoch: integer(),
          continuation_hint: String.t() | nil
        }

  @enforce_keys [:observations, :token_count, :message_ids, :message_tokens, :epoch]
  defstruct [
    :observations,
    :token_count,
    :message_ids,
    :message_tokens,
    :epoch,
    :continuation_hint
  ]
end
