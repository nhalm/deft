defmodule Deft.Session.Entry do
  @moduledoc """
  Entry types for session JSONL persistence.

  Each entry type represents a distinct event in the session timeline.
  All entries are serialized as JSON lines to `~/.deft/sessions/<session_id>.jsonl`.
  """

  alias Deft.Session.Entry.{
    SessionStart,
    Message,
    ToolResult,
    ModelChange,
    Observation,
    Compaction,
    Cost
  }

  @type t ::
          SessionStart.t()
          | Message.t()
          | ToolResult.t()
          | ModelChange.t()
          | Observation.t()
          | Compaction.t()
          | Cost.t()
end

defmodule Deft.Session.Entry.SessionStart do
  @moduledoc """
  Session metadata entry.

  Written once at session creation. Contains the session ID, creation
  timestamp, working directory, initial model, and config snapshot.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :session_start,
          session_id: String.t(),
          created_at: DateTime.t(),
          working_dir: String.t(),
          model: String.t(),
          config: map()
        }

  @enforce_keys [:type, :session_id, :created_at, :working_dir, :model, :config]
  defstruct [:type, :session_id, :created_at, :working_dir, :model, :config]

  @doc """
  Creates a new SessionStart entry.
  """
  def new(session_id, working_dir, model, config) do
    %__MODULE__{
      type: :session_start,
      session_id: session_id,
      created_at: DateTime.utc_now(),
      working_dir: working_dir,
      model: model,
      config: config
    }
  end
end

defmodule Deft.Session.Entry.Message do
  @moduledoc """
  Conversation message entry.

  Records a message from the user or assistant. Contains the message ID,
  role, content blocks, and timestamp.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :message,
          message_id: String.t(),
          role: :user | :assistant | :system,
          content: [map()],
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :message_id, :role, :content, :timestamp]
  defstruct [:type, :message_id, :role, :content, :timestamp]

  @doc """
  Creates a new Message entry from a Deft.Message struct.
  """
  def from_message(%Deft.Message{} = msg) do
    %__MODULE__{
      type: :message,
      message_id: msg.id,
      role: msg.role,
      content: serialize_content(msg.content),
      timestamp: msg.timestamp
    }
  end

  # Serialize content blocks to JSON-friendly format
  defp serialize_content(content) when is_list(content) do
    Enum.map(content, fn
      %Deft.Message.Text{text: text} ->
        %{type: "text", text: text}

      %Deft.Message.ToolUse{id: id, name: name, args: args} ->
        %{type: "tool_use", id: id, name: name, args: args}

      %Deft.Message.ToolResult{
        tool_use_id: tool_use_id,
        name: name,
        content: content,
        is_error: is_error
      } ->
        %{
          type: "tool_result",
          tool_use_id: tool_use_id,
          name: name,
          content: content,
          is_error: is_error
        }

      %Deft.Message.Thinking{text: text} ->
        %{type: "thinking", text: text}

      %Deft.Message.Image{media_type: media_type, data: data} ->
        %{type: "image", media_type: media_type, data: data}
    end)
  end
end

defmodule Deft.Session.Entry.ToolResult do
  @moduledoc """
  Tool execution result entry.

  Records the outcome of a tool execution, including timing and error status.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :tool_result,
          tool_call_id: String.t(),
          name: String.t(),
          result: String.t(),
          duration_ms: non_neg_integer(),
          is_error: boolean(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :tool_call_id, :name, :result, :duration_ms, :is_error, :timestamp]
  defstruct [:type, :tool_call_id, :name, :result, :duration_ms, :is_error, :timestamp]

  @doc """
  Creates a new ToolResult entry.
  """
  def new(tool_call_id, name, result, duration_ms, is_error) do
    %__MODULE__{
      type: :tool_result,
      tool_call_id: tool_call_id,
      name: name,
      result: result,
      duration_ms: duration_ms,
      is_error: is_error,
      timestamp: DateTime.utc_now()
    }
  end
end

defmodule Deft.Session.Entry.ModelChange do
  @moduledoc """
  Model change entry.

  Records when the user switches models mid-session.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :model_change,
          from_model: String.t(),
          to_model: String.t(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :from_model, :to_model, :timestamp]
  defstruct [:type, :from_model, :to_model, :timestamp]

  @doc """
  Creates a new ModelChange entry.
  """
  def new(from_model, to_model) do
    %__MODULE__{
      type: :model_change,
      from_model: from_model,
      to_model: to_model,
      timestamp: DateTime.utc_now()
    }
  end
end

defmodule Deft.Session.Entry.Observation do
  @moduledoc """
  OM state snapshot entry.

  Persists the observational memory state for session resume.
  See observational-memory spec section 9.2 for details.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :observation,
          active_observations: String.t(),
          observation_tokens: non_neg_integer(),
          observed_message_ids: [String.t()],
          pending_message_tokens: non_neg_integer(),
          generation_count: non_neg_integer(),
          last_observed_at: DateTime.t() | nil,
          activation_epoch: non_neg_integer(),
          calibration_factor: float(),
          timestamp: DateTime.t()
        }

  @enforce_keys [
    :type,
    :active_observations,
    :observation_tokens,
    :observed_message_ids,
    :pending_message_tokens,
    :generation_count,
    :activation_epoch,
    :calibration_factor,
    :timestamp
  ]

  defstruct [
    :type,
    :active_observations,
    :observation_tokens,
    :observed_message_ids,
    :pending_message_tokens,
    :generation_count,
    :last_observed_at,
    :activation_epoch,
    :calibration_factor,
    :timestamp
  ]

  @doc """
  Creates a new Observation entry from OM state.

  Per spec section 9.2, includes all persisted fields:
  - active_observations
  - observation_tokens
  - observed_message_ids
  - pending_message_tokens
  - generation_count
  - last_observed_at
  - activation_epoch
  - calibration_factor
  """
  def new(
        active_observations,
        observation_tokens,
        observed_message_ids,
        pending_message_tokens,
        generation_count,
        last_observed_at,
        activation_epoch,
        calibration_factor
      ) do
    %__MODULE__{
      type: :observation,
      active_observations: active_observations,
      observation_tokens: observation_tokens,
      observed_message_ids: observed_message_ids,
      pending_message_tokens: pending_message_tokens,
      generation_count: generation_count,
      last_observed_at: last_observed_at,
      activation_epoch: activation_epoch,
      calibration_factor: calibration_factor,
      timestamp: DateTime.utc_now()
    }
  end
end

defmodule Deft.Session.Entry.Compaction do
  @moduledoc """
  Context compaction entry.

  Records when messages are summarized to manage context window.
  Used as a fallback when OM is disabled.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :compaction,
          summary: String.t(),
          messages_removed: non_neg_integer(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :summary, :messages_removed, :timestamp]
  defstruct [:type, :summary, :messages_removed, :timestamp]

  @doc """
  Creates a new Compaction entry.
  """
  def new(summary, messages_removed) do
    %__MODULE__{
      type: :compaction,
      summary: summary,
      messages_removed: messages_removed,
      timestamp: DateTime.utc_now()
    }
  end
end

defmodule Deft.Session.Entry.Cost do
  @moduledoc """
  Cost checkpoint entry.

  Tracks cumulative session cost at a point in time.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          type: :cost,
          cumulative_cost: float(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :cumulative_cost, :timestamp]
  defstruct [:type, :cumulative_cost, :timestamp]

  @doc """
  Creates a new Cost entry.
  """
  def new(cumulative_cost) do
    %__MODULE__{
      type: :cost,
      cumulative_cost: cumulative_cost,
      timestamp: DateTime.utc_now()
    }
  end
end
