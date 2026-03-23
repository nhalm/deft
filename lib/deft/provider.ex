defmodule Deft.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Providers abstract API differences behind a common interface. Each provider
  implements this behaviour to handle streaming requests, event parsing, and
  message/tool formatting for their specific API.

  ## Event Flow

  1. Caller invokes `stream/3` with messages, tools, and config
  2. Provider starts streaming HTTP request and returns `{:ok, stream_ref}`
  3. Provider sends `{:provider_event, event}` messages to caller's mailbox
  4. Caller can cancel stream at any time with `cancel_stream/1`
  5. Provider sends `{:provider_event, %Done{}}` when complete

  ## Stream Lifecycle

  - `stream/3` returns a stream reference (opaque term)
  - Provider process sends events to caller via mailbox
  - Caller monitors the stream process (handles `:DOWN` on crash)
  - `cancel_stream/1` cleanly terminates the stream
  """

  alias Deft.Provider.Event.{
    TextDelta,
    ThinkingDelta,
    ToolCallStart,
    ToolCallDelta,
    ToolCallDone,
    Usage,
    Done,
    Error
  }

  @type stream_ref :: term()
  @type event ::
          TextDelta.t()
          | ThinkingDelta.t()
          | ToolCallStart.t()
          | ToolCallDelta.t()
          | ToolCallDone.t()
          | Usage.t()
          | Done.t()
          | Error.t()
  @type messages :: [Deft.Message.t()]
  @type tools :: [module()]
  @type config :: map()
  @type provider_messages :: term()
  @type provider_tools :: term()
  @type raw_event :: term()
  @type model_config :: %{
          context_window: non_neg_integer(),
          max_output: non_neg_integer(),
          input_price_per_mtok: float(),
          output_price_per_mtok: float()
        }

  @doc """
  Initiates a streaming request to the provider's API.

  Returns a stream reference that can be used to cancel the stream later.
  The provider sends `{:provider_event, event}` messages to the caller's
  mailbox as events arrive.

  ## Parameters

  - `messages` - List of Deft.Message structs representing the conversation
  - `tools` - List of tool modules implementing the Deft.Tool behaviour
  - `config` - Provider configuration (model name, temperature, etc.)

  ## Returns

  - `{:ok, stream_ref}` - Stream started successfully
  - `{:error, reason}` - Failed to start stream
  """
  @callback stream(messages(), tools(), config()) ::
              {:ok, stream_ref()} | {:error, term()}

  @doc """
  Cancels an in-flight streaming request.

  Cleanly terminates the HTTP connection and stops sending events.
  Idempotent - safe to call multiple times or on already-completed streams.

  ## Parameters

  - `stream_ref` - Reference returned from `stream/3`

  ## Returns

  - `:ok` - Stream cancelled (or was already complete)
  """
  @callback cancel_stream(stream_ref()) :: :ok

  @doc """
  Parses a raw provider event into a common event type.

  Converts provider-specific event formats (e.g., Anthropic's
  content_block_delta) into normalized Deft event structs.

  ## Parameters

  - `raw_event` - Raw event from the provider's SSE stream

  ## Returns

  - Normalized event struct (TextDelta, ToolCallStart, etc.)
  - `:skip` if the event should be ignored
  """
  @callback parse_event(raw_event()) :: event() | :skip

  @doc """
  Converts Deft.Message structs to provider wire format.

  Transforms the canonical internal message format into the specific
  JSON structure expected by the provider's API.

  ## Parameters

  - `messages` - List of Deft.Message structs

  ## Returns

  - Provider-specific message format (map, list, etc.)
  """
  @callback format_messages(messages()) :: provider_messages()

  @doc """
  Converts tool modules to provider tool definitions.

  Extracts tool metadata (name, description, parameters) and formats
  it for the provider's API.

  ## Parameters

  - `tools` - List of modules implementing Deft.Tool behaviour

  ## Returns

  - Provider-specific tools format (usually list of maps)
  """
  @callback format_tools(tools()) :: provider_tools()

  @doc """
  Returns configuration for a specific model.

  Provides model metadata like context window size, max output tokens,
  and pricing information.

  ## Parameters

  - `model_name` - String identifier for the model (e.g., "claude-sonnet-4-20250514")

  ## Returns

  - Map with model configuration
  - `{:error, :unknown_model}` if model not supported
  """
  @callback model_config(String.t()) :: model_config() | {:error, :unknown_model}
end

defmodule Deft.Provider.Event.TextDelta do
  @moduledoc """
  Incremental text chunk from the assistant's response.
  """

  @type t :: %__MODULE__{
          delta: String.t()
        }

  @enforce_keys [:delta]
  defstruct [:delta]
end

defmodule Deft.Provider.Event.ThinkingDelta do
  @moduledoc """
  Incremental thinking/reasoning chunk.

  Extended thinking content that shows the model's internal reasoning.
  Only emitted by models that support extended thinking.
  """

  @type t :: %__MODULE__{
          delta: String.t()
        }

  @enforce_keys [:delta]
  defstruct [:delta]
end

defmodule Deft.Provider.Event.ToolCallStart do
  @moduledoc """
  Beginning of a tool call.

  Signals that the model has decided to call a tool. The full arguments
  will arrive in subsequent ToolCallDelta events.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t()
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name]
end

defmodule Deft.Provider.Event.ToolCallDelta do
  @moduledoc """
  Incremental tool call arguments (JSON fragment).

  The delta contains a partial JSON string that should be accumulated
  until ToolCallDone is received with the complete parsed arguments.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          delta: String.t()
        }

  @enforce_keys [:id, :delta]
  defstruct [:id, :delta]
end

defmodule Deft.Provider.Event.ToolCallDone do
  @moduledoc """
  Complete tool call with parsed arguments.

  Signals the end of a tool call. The args map contains the fully
  parsed JSON arguments ready for execution.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          args: map()
        }

  @enforce_keys [:id, :args]
  defstruct [:id, :args]
end

defmodule Deft.Provider.Event.Usage do
  @moduledoc """
  Token usage report.

  Tracks input and output tokens consumed by this request.
  Used for cost tracking and observability.
  """

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer()
        }

  @enforce_keys [:input, :output]
  defstruct [:input, :output]
end

defmodule Deft.Provider.Event.Done do
  @moduledoc """
  Stream complete.

  Signals that the provider has finished sending events for this request.
  No more events will arrive for this stream.
  """

  @type t :: %__MODULE__{}

  defstruct []
end

defmodule Deft.Provider.Event.Error do
  @moduledoc """
  Provider error.

  Indicates an error from the provider (API error, network failure, etc.).
  The stream is considered terminated after an error event.
  """

  @type t :: %__MODULE__{
          message: String.t()
        }

  @enforce_keys [:message]
  defstruct [:message]
end
