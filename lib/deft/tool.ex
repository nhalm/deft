defmodule Deft.Tool do
  @moduledoc """
  Behaviour for Deft tools.

  Every tool implements this behaviour, providing its name, description,
  parameter schema, and execution logic. Tools are executed in supervised
  Tasks and cannot crash the agent.
  """

  alias Deft.Message

  @doc """
  Returns the tool's name as a string.

  This name is sent to the LLM and used in tool calls.
  """
  @callback name() :: String.t()

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
end

defmodule Deft.Tool.Context do
  @moduledoc """
  Context provided to tools during execution.

  ## Fields

  - `working_dir` - The directory the session is operating in
  - `session_id` - Current session identifier
  - `emit` - Function for streaming incremental output (e.g., bash stdout)
  - `file_scope` - Optional list of allowed paths for write/edit operations
  - `bash_timeout` - Timeout in milliseconds for bash tool execution
  """

  @enforce_keys [:working_dir, :session_id, :emit, :bash_timeout]
  defstruct [:working_dir, :session_id, :emit, :file_scope, :bash_timeout]

  @type t :: %__MODULE__{
          working_dir: String.t(),
          session_id: String.t(),
          emit: (String.t() -> :ok),
          file_scope: [String.t()] | nil,
          bash_timeout: pos_integer()
        }
end
