defmodule Deft.Tool do
  @moduledoc """
  Behaviour for Deft tools.

  Every tool implements this behaviour, providing its name, description,
  parameter schema, and execution logic. Tools are executed in supervised
  Tasks and cannot crash the agent.
  """

  alias Deft.Message

  @typedoc "Tool name identifier"
  @type tool_name :: String.t()

  @typedoc "Tool call identifier"
  @type tool_call_id :: String.t()

  @doc """
  Returns the tool's name as a string.

  This name is sent to the LLM and used in tool calls.
  """
  @callback name() :: tool_name()

  @doc """
  Returns a description of what the tool does.

  This description is included in the system prompt to help the LLM
  understand when and how to use the tool.
  """
  @callback description() :: String.t()

  @doc """
  Returns the JSON Schema for the tool's parameters.

  Should be a map with `type: "object"`, `properties`, and `required` fields
  following the JSON Schema specification.
  """
  @callback parameters() :: map()

  @doc """
  Executes the tool with the given arguments and context.

  Returns either:
  - `{:ok, [ContentBlock.t()]}` - List of content blocks (typically a single Text block)
  - `{:error, String.t()}` - Error message

  The agent loop wraps the result into a ToolResult message for the LLM.
  """
  @callback execute(args :: map(), context :: Deft.Tool.Context.t()) ::
              {:ok, [Message.content_block()]} | {:error, String.t()}

  @doc """
  Summarizes a large tool result for cache spilling.

  This callback is optional. If not implemented, the full result will be stored
  without summarization when spilling to cache.

  Returns a summary string with key information from the full result.
  The summary should include a reference to the cache key.

  ## Arguments

  - `full_result` - The complete tool result (list of content blocks)
  - `cache_key` - The cache key where the full result is stored
  """
  @callback summarize(full_result :: [Message.content_block()], cache_key :: String.t()) ::
              String.t()

  @optional_callbacks summarize: 2
end

defmodule Deft.Tool.Context do
  @moduledoc """
  Context provided to tools during execution.

  ## Fields

  - `working_dir` - The directory the session is operating in
  - `session_id` - Current session identifier
  - `lead_id` - Lead identifier for cache isolation (defaults to "main" for single-agent sessions)
  - `emit` - Function for streaming incremental output (e.g., bash stdout)
  - `file_scope` - Optional list of allowed paths for write/edit operations
  - `bash_timeout` - Timeout in milliseconds for bash tool execution
  - `cache_tid` - Optional ETS table ID for cache access (present when cache is active)
  - `cache_config` - Optional map of cache configuration (token thresholds per tool)
  """

  @enforce_keys [:working_dir, :session_id, :emit, :bash_timeout]
  defstruct [
    :working_dir,
    :session_id,
    :emit,
    :file_scope,
    :bash_timeout,
    :cache_tid,
    :cache_config,
    lead_id: "main"
  ]

  @type t :: %__MODULE__{
          working_dir: String.t(),
          session_id: Deft.Session.session_id(),
          lead_id: Deft.Job.lead_id(),
          emit: (String.t() -> :ok),
          file_scope: [String.t()] | nil,
          bash_timeout: pos_integer(),
          cache_tid: reference() | nil,
          cache_config: %{optional(String.t()) => pos_integer()} | nil
        }
end
