defmodule Deft.Issue do
  @moduledoc """
  Persistent issue tracking for Deft work queues.

  An issue represents a bug, task, or feature to be implemented. Issues are
  stored as JSONL in `.deft/issues.jsonl` and feed into the orchestration
  layer via `deft work`.

  All timestamps use ISO 8601 UTC format via `DateTime.utc_now() |> DateTime.to_iso8601()`.
  """

  require Logger

  @derive Jason.Encoder
  @type id :: String.t()
  @type status :: :open | :in_progress | :closed
  @type priority :: 0..4
  @type source :: :user | :agent

  @type t :: %__MODULE__{
          id: id(),
          title: String.t(),
          context: String.t(),
          acceptance_criteria: [String.t()],
          constraints: [String.t()],
          status: status(),
          priority: priority(),
          dependencies: [id()],
          created_at: String.t(),
          updated_at: String.t(),
          closed_at: String.t() | nil,
          source: source(),
          job_id: Deft.Job.job_id() | nil
        }

  @enforce_keys [
    :id,
    :title,
    :context,
    :acceptance_criteria,
    :constraints,
    :status,
    :priority,
    :dependencies,
    :created_at,
    :updated_at,
    :source
  ]

  defstruct [
    :id,
    :title,
    :context,
    :acceptance_criteria,
    :constraints,
    :status,
    :priority,
    :dependencies,
    :created_at,
    :updated_at,
    :closed_at,
    :source,
    :job_id
  ]

  @doc """
  Encodes an issue to a JSON string.

  Returns `{:ok, json_string}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> issue = %Deft.Issue{
      ...>   id: "deft-a1b2",
      ...>   title: "Fix bug",
      ...>   context: "The bug needs fixing",
      ...>   acceptance_criteria: ["Bug is fixed"],
      ...>   constraints: [],
      ...>   status: :open,
      ...>   priority: 2,
      ...>   dependencies: [],
      ...>   created_at: "2026-03-17T12:00:00Z",
      ...>   updated_at: "2026-03-17T12:00:00Z",
      ...>   closed_at: nil,
      ...>   source: :user,
      ...>   job_id: nil
      ...> }
      iex> {:ok, _json} = Deft.Issue.encode(issue)
      {:ok, _}
  """
  def encode(%__MODULE__{} = issue) do
    Jason.encode(issue)
  end

  @doc """
  Decodes a JSON string to an issue struct.

  Returns `{:ok, issue}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> json = ~s({"id":"deft-a1b2","title":"Fix bug","context":"","acceptance_criteria":[],"constraints":[],"status":"open","priority":2,"dependencies":[],"created_at":"2026-03-17T12:00:00Z","updated_at":"2026-03-17T12:00:00Z","closed_at":null,"source":"user","job_id":null})
      iex> {:ok, issue} = Deft.Issue.decode(json)
      iex> issue.id
      "deft-a1b2"
  """
  def decode(json) when is_binary(json) do
    with {:ok, data} <- Jason.decode(json, keys: :atoms),
         {:ok, issue} <- from_map(data) do
      {:ok, issue}
    end
  end

  @doc """
  Converts a map (typically from JSON decoding) to an issue struct.

  Handles string-to-atom conversion for status and source fields.
  Returns `{:ok, issue}` on success, `{:error, reason}` if required fields are missing.
  """
  def from_map(data) when is_map(data) do
    required_fields = [
      :id,
      :title,
      :context,
      :acceptance_criteria,
      :constraints,
      :status,
      :priority,
      :dependencies,
      :created_at,
      :updated_at,
      :source
    ]

    missing_fields =
      Enum.reject(required_fields, fn field ->
        Map.has_key?(data, field)
      end)

    if missing_fields == [] do
      {:ok,
       %__MODULE__{
         id: data.id,
         title: data.title,
         context: data.context,
         acceptance_criteria: data.acceptance_criteria,
         constraints: data.constraints,
         status: normalize_status(data.status),
         priority: data.priority,
         dependencies: data.dependencies,
         created_at: data.created_at,
         updated_at: data.updated_at,
         closed_at: data[:closed_at],
         source: normalize_source(data.source),
         job_id: data[:job_id]
       }}
    else
      {:error, {:missing_required_fields, missing_fields}}
    end
  end

  # Normalize status field to atom if it's a string
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("open"), do: :open
  defp normalize_status("in_progress"), do: :in_progress
  defp normalize_status("closed"), do: :closed

  defp normalize_status(invalid) do
    Logger.warning("Unrecognized status value: #{inspect(invalid)}, defaulting to :open")
    :open
  end

  # Normalize source field to atom if it's a string
  defp normalize_source(source) when is_atom(source), do: source
  defp normalize_source("user"), do: :user
  defp normalize_source("agent"), do: :agent

  defp normalize_source(invalid) do
    Logger.warning("Unrecognized source value: #{inspect(invalid)}, defaulting to :user")
    :user
  end

  @doc """
  Returns a timestamp string in ISO 8601 UTC format.

  This is the canonical timestamp format for all Issue fields.

  ## Examples

      iex> ts = Deft.Issue.timestamp()
      iex> String.match?(ts, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      true
  """
  def timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
