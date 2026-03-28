defmodule Deft.Skills.Registry do
  @moduledoc """
  Agent-based registry for skills and commands.

  On init, scans three levels (built-in → global → project) for:
  - Skills: YAML files in `*/skills/*.yaml` with manifest + definition
  - Commands: Markdown files in `*/commands/*.md` (just prompts)

  Cascade priority: project > global > built-in.
  Single namespace: skill wins over command at same cascade level.

  The registry holds manifests (name, description) loaded at startup.
  Full definitions are loaded on demand via `load_definition/1`.
  """

  use Agent
  require Logger
  alias Deft.Skills.Entry

  @name_pattern ~r/^[a-z][a-z0-9-]*$/

  @type registry :: %{String.t() => Entry.t()}

  ## Public API

  @doc """
  Starts the Skills Registry.

  Options:
  - `:project_dir` - Override project directory (default: `File.cwd!/0`)
  """
  def start_link(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    Agent.start_link(
      fn ->
        try do
          discover_all(project_dir)
        rescue
          e ->
            Logger.warning("[Skills] Skills Registry discovery failed: #{inspect(e)}")
            %{}
        end
      end,
      name: __MODULE__
    )
  end

  @doc """
  Returns all registry entries, sorted by name.
  """
  @spec list() :: [Entry.t()]
  def list do
    Agent.get(__MODULE__, fn registry ->
      registry
      |> Map.values()
      |> Enum.sort_by(& &1.name)
    end)
  end

  @doc """
  Looks up an entry by name.

  Returns the entry or `:not_found`.
  """
  @spec lookup(String.t()) :: Entry.t() | :not_found
  def lookup(name) do
    Agent.get(__MODULE__, fn registry ->
      Map.get(registry, name, :not_found)
    end)
  end

  @doc """
  Loads the full definition for a skill or command.

  Uses atomic get_and_update to cache the definition on first load.
  Returns `{:ok, definition}` or an error.

  Errors:
  - `{:error, :not_found}` - No entry with that name
  - `{:error, :no_definition}` - Entry exists but has no definition (manifest-only)
  - `{:error, reason}` - File read or parse error
  """
  @spec load_definition(String.t()) :: {:ok, String.t()} | {:error, atom() | String.t()}
  def load_definition(name) do
    Agent.get_and_update(__MODULE__, fn registry ->
      handle_load_definition(Map.get(registry, name), name, registry)
    end)
  end

  defp handle_load_definition(nil, _name, registry) do
    {{:error, :not_found}, registry}
  end

  defp handle_load_definition(%Entry{loaded: true, definition: definition}, _name, registry) do
    # Already loaded - return cached definition
    {{:ok, definition}, registry}
  end

  defp handle_load_definition(entry, name, registry) do
    # First load - read, cache, and mark as loaded
    case read_definition(entry) do
      {:ok, definition} = result ->
        updated_entry = %{entry | loaded: true, definition: definition}
        updated_registry = Map.put(registry, name, updated_entry)
        {result, updated_registry}

      error ->
        {error, registry}
    end
  end

  @doc """
  Re-scans project-level skills and commands.

  Removes all existing project-level entries from the registry and
  replaces them with freshly discovered ones from the project directory.
  Built-in and global skills persist unchanged.

  Called at session start to pick up changes to `.deft/skills/` and
  `.deft/commands/` without affecting application-global skills.
  """
  @spec rescan_project(String.t()) :: :ok
  def rescan_project(project_dir) do
    Agent.update(__MODULE__, fn registry ->
      # Remove existing project-level entries
      non_project =
        registry
        |> Enum.reject(fn {_name, entry} -> entry.level == :project end)
        |> Map.new()

      # Discover fresh project entries from .deft/ subdirectory
      project_deft_dir = Path.join(project_dir, ".deft")
      project_entries = discover_level(project_deft_dir, :project)

      # Merge project over non-project (preserving cascade)
      Map.merge(non_project, project_entries)
    end)
  end

  ## Discovery

  defp discover_all(project_dir) do
    builtin_dir =
      try do
        Application.app_dir(:deft, "priv")
      rescue
        _ -> nil
      end

    global_dir = Path.expand("~/.deft")
    project_deft_dir = Path.join(project_dir, ".deft")

    # Scan each level (nil directories are handled gracefully by discover_level)
    builtin_entries = if builtin_dir, do: discover_level(builtin_dir, :builtin), else: %{}
    global_entries = discover_level(global_dir, :global)
    project_entries = discover_level(project_deft_dir, :project)

    # Apply cascade: project > global > builtin
    # Later entries override earlier ones
    builtin_entries
    |> Map.merge(global_entries)
    |> Map.merge(project_entries)
  end

  defp discover_level(base_dir, level) do
    skills = discover_skills(base_dir, level)
    commands = discover_commands(base_dir, level)

    # Merge with skill winning at same level
    Map.merge(commands, skills)
  end

  defp discover_skills(base_dir, level) do
    skills_dir = Path.join([base_dir, "skills"])

    if File.dir?(skills_dir) do
      skills_dir
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        accumulate_skill(parse_skill_manifest(path, level), path, level, acc)
      end)
    else
      %{}
    end
  end

  defp accumulate_skill({:ok, entry}, _path, level, acc) do
    Logger.info("[Skills] Skill registered: #{entry.name} (level: #{level})")
    Map.put(acc, entry.name, entry)
  end

  defp accumulate_skill({:error, reason}, path, _level, acc) do
    Logger.warning("[Skills] Skipping skill #{path}: #{inspect(reason)}")
    acc
  end

  defp discover_commands(base_dir, level) do
    commands_dir = Path.join([base_dir, "commands"])

    if File.dir?(commands_dir) do
      commands_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        accumulate_command(path, level, acc)
      end)
    else
      %{}
    end
  end

  defp accumulate_command(path, level, acc) do
    Logger.debug("[Skills] Parsing command file: #{path}")
    name = path |> Path.basename(".md")

    if valid_name?(name) do
      description = extract_command_description(path)

      entry = %Entry{
        name: name,
        type: :command,
        level: level,
        description: description,
        path: path,
        loaded: false
      }

      Map.put(acc, name, entry)
    else
      Logger.warning(
        "[Skills] Skipping command #{path}: name does not match #{inspect(@name_pattern)}"
      )

      acc
    end
  end

  defp parse_skill_manifest(path, level) do
    Logger.debug("[Skills] Parsing skill file: #{path}")

    with {:ok, content} <- File.read(path),
         {:ok, name, manifest} <- parse_yaml_manifest(content) do
      validate_and_build_skill_entry(name, manifest, path, level)
    end
  end

  defp validate_and_build_skill_entry(name, manifest, path, level) do
    if valid_name?(name) do
      entry = %Entry{
        name: name,
        type: :skill,
        level: level,
        description: manifest["description"],
        path: path,
        loaded: false
      }

      validate_skill_entry_description(entry)
    else
      {:error, :invalid_name}
    end
  end

  defp validate_skill_entry_description(%Entry{description: nil}),
    do: {:error, :missing_description}

  defp validate_skill_entry_description(entry), do: {:ok, entry}

  defp parse_yaml_manifest(content) do
    case String.split(content, "\n---\n", parts: 2) do
      [yaml_part | _rest] ->
        parse_yaml_string(yaml_part)

      [] ->
        {:error, :empty_file}
    end
  end

  defp parse_yaml_string(yaml_part) do
    case YamlElixir.read_from_string(yaml_part) do
      {:ok, manifest} when is_map(manifest) ->
        extract_manifest_name(manifest)

      {:error, reason} ->
        {:error, {:yaml_parse_error, reason}}

      _ ->
        {:error, :invalid_yaml_format}
    end
  end

  defp extract_manifest_name(manifest) do
    case manifest["name"] do
      nil -> {:error, :missing_name}
      name -> {:ok, name, manifest}
    end
  end

  defp valid_name?(name) do
    Regex.match?(@name_pattern, name)
  end

  defp extract_command_description(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find(&(String.trim(&1) != ""))
        |> case do
          nil -> nil
          line -> String.trim(line)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp read_definition(%Entry{type: :command, path: path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_definition(%Entry{type: :skill, path: path}) do
    with {:ok, content} <- File.read(path) do
      case String.split(content, "\n---\n", parts: 2) do
        [_manifest, definition] ->
          {:ok, definition}

        [_manifest_only] ->
          {:error, :no_definition}
      end
    end
  end
end
