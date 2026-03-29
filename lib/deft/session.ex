defmodule Deft.Session do
  @moduledoc """
  Session management and persistence.

  A session represents a conversation history and associated state. Sessions are
  persisted to disk as JSONL files and can be loaded, resumed, and extended.

  This module defines shared types used across the Session subsystem (Store,
  Worker, Supervisor, Entry).
  """

  @typedoc """
  Unique identifier for a session.

  Session IDs are used to locate session files on disk, reference sessions in
  observational memory, and track which session a tool execution belongs to.
  """
  @type session_id :: String.t()
end
