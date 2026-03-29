defmodule Deft.Message do
  @moduledoc """
  Canonical internal message format used across all layers of Deft.

  A message has:
  - `id`: unique identifier for this message
  - `role`: who sent the message (`:system`, `:user`, or `:assistant`)
  - `content`: list of content blocks
  - `timestamp`: when the message was created

  Content blocks are structured data representing different types of content
  in a message (text, tool use, tool results, thinking, images).
  """

  alias Deft.Message.{Text, ToolUse, ToolResult, Thinking, Image}

  @typedoc "Unique identifier for a message"
  @type id :: String.t()

  @typedoc "Role of the message sender"
  @type role :: :system | :user | :assistant

  @typedoc "Union type for all content block types"
  @type content_block :: Text.t() | ToolUse.t() | ToolResult.t() | Thinking.t() | Image.t()

  @type t :: %__MODULE__{
          id: id(),
          role: role(),
          content: [content_block()],
          timestamp: DateTime.t()
        }

  @enforce_keys [:id, :role, :content, :timestamp]
  defstruct [:id, :role, :content, :timestamp]
end

defmodule Deft.Message.Text do
  @moduledoc """
  A text content block.

  Represents plain text content in a message.
  """

  @type t :: %__MODULE__{
          text: String.t()
        }

  @enforce_keys [:text]
  defstruct [:text]
end

defmodule Deft.Message.ToolUse do
  @moduledoc """
  A tool use content block.

  Represents a request to execute a tool with specific arguments.
  """

  @type t :: %__MODULE__{
          id: Deft.Tool.tool_call_id(),
          name: Deft.Tool.tool_name(),
          args: map()
        }

  @enforce_keys [:id, :name, :args]
  defstruct [:id, :name, :args]
end

defmodule Deft.Message.ToolResult do
  @moduledoc """
  A tool result content block.

  Represents the result of a tool execution.
  """

  @type t :: %__MODULE__{
          tool_use_id: Deft.Tool.tool_call_id(),
          name: Deft.Tool.tool_name(),
          content: String.t(),
          is_error: boolean()
        }

  @enforce_keys [:tool_use_id, :name, :content, :is_error]
  defstruct [:tool_use_id, :name, :content, :is_error]
end

defmodule Deft.Message.Thinking do
  @moduledoc """
  A thinking content block.

  Represents model reasoning or internal thought process.
  """

  @type t :: %__MODULE__{
          text: String.t()
        }

  @enforce_keys [:text]
  defstruct [:text]
end

defmodule Deft.Message.Image do
  @moduledoc """
  An image content block.

  Represents an image with media type and base64-encoded data.
  """

  @type t :: %__MODULE__{
          media_type: String.t(),
          data: String.t(),
          filename: String.t() | nil
        }

  @enforce_keys [:media_type, :data]
  defstruct [:media_type, :data, :filename]
end
