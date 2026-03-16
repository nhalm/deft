defmodule Deft.Config do
  @moduledoc """
  Configuration loading and validation for Deft.

  Merges configuration from multiple sources in priority order:
  1. CLI flags (highest priority)
  2. Project config (`.deft/config.yaml` in working directory)
  3. User config (`~/.deft/config.yaml`)
  4. Defaults (lowest priority)
  """

  @type t :: %__MODULE__{
          model: String.t(),
          provider: String.t(),
          turn_limit: pos_integer(),
          tool_timeout: pos_integer(),
          bash_timeout: pos_integer(),
          om_enabled: boolean(),
          om_observer_model: String.t(),
          om_reflector_model: String.t()
        }

  @enforce_keys [
    :model,
    :provider,
    :turn_limit,
    :tool_timeout,
    :bash_timeout,
    :om_enabled,
    :om_observer_model,
    :om_reflector_model
  ]

  defstruct [
    :model,
    :provider,
    :turn_limit,
    :tool_timeout,
    :bash_timeout,
    :om_enabled,
    :om_observer_model,
    :om_reflector_model
  ]

  @doc """
  Loads and merges configuration from all sources.

  ## Parameters

    * `cli_flags` - Map of CLI flag overrides (e.g., `%{model: "claude-opus-4"}`)
    * `working_dir` - Working directory path for resolving project config
    * `opts` - Optional keyword list with `:user_home` for testing

  ## Returns

  A validated `Deft.Config` struct with merged configuration.

  ## Examples

      iex> Deft.Config.load(%{}, "/path/to/project")
      %Deft.Config{
        model: "claude-sonnet-4",
        provider: "anthropic",
        turn_limit: 25,
        # ...
      }
  """
  @spec load(map(), String.t(), keyword()) :: t()
  def load(cli_flags \\ %{}, working_dir \\ File.cwd!(), opts \\ []) do
    user_home = Keyword.get(opts, :user_home, System.user_home!())

    defaults()
    |> merge_user_config(user_home)
    |> merge_project_config(working_dir)
    |> merge_cli_flags(cli_flags)
    |> validate_and_build()
  end

  @doc """
  Returns the default configuration.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      model: "claude-sonnet-4",
      provider: "anthropic",
      turn_limit: 25,
      tool_timeout: 120_000,
      bash_timeout: 120_000,
      om: %{
        enabled: true,
        observer_model: "claude-haiku-4.5",
        reflector_model: "claude-haiku-4.5"
      }
    }
  end

  # Merge user config from ~/.deft/config.yaml
  defp merge_user_config(config, user_home) do
    user_config_path = Path.join([user_home, ".deft", "config.yaml"])

    case load_yaml_file(user_config_path) do
      {:ok, user_config} -> deep_merge(config, user_config)
      {:error, _} -> config
    end
  end

  # Merge project config from .deft/config.yaml in working_dir
  defp merge_project_config(config, working_dir) do
    project_config_path = Path.join([working_dir, ".deft", "config.yaml"])

    case load_yaml_file(project_config_path) do
      {:ok, project_config} -> deep_merge(config, project_config)
      {:error, _} -> config
    end
  end

  # Merge CLI flags (highest priority)
  defp merge_cli_flags(config, cli_flags) do
    # CLI flags use flat structure, need to handle om.* specially
    cli_config = normalize_cli_flags(cli_flags)
    deep_merge(config, cli_config)
  end

  # Normalize CLI flags to nested structure
  defp normalize_cli_flags(flags) do
    flags
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case key do
        :om_enabled ->
          Map.update(acc, :om, %{enabled: value}, fn om -> Map.put(om, :enabled, value) end)

        :om_observer_model ->
          Map.update(acc, :om, %{observer_model: value}, fn om ->
            Map.put(om, :observer_model, value)
          end)

        :om_reflector_model ->
          Map.update(acc, :om, %{reflector_model: value}, fn om ->
            Map.put(om, :reflector_model, value)
          end)

        _ ->
          Map.put(acc, key, value)
      end
    end)
  end

  # Load and parse YAML file
  defp load_yaml_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      # YamlElixir.read_from_string can return either a single map or a list
      result =
        case parsed do
          [single_doc] -> single_doc
          doc when is_map(doc) -> doc
          [] -> %{}
          _ -> %{}
        end

      {:ok, atomize_keys(result)}
    else
      {:error, _} = error -> error
    end
  end

  # Convert string keys to atom keys recursively
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value

  # Deep merge two maps, with right taking precedence
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right

  # Validate and build the Config struct
  defp validate_and_build(config) do
    om_config = Map.get(config, :om, %{})

    %__MODULE__{
      model: Map.fetch!(config, :model),
      provider: Map.fetch!(config, :provider),
      turn_limit: Map.fetch!(config, :turn_limit),
      tool_timeout: Map.fetch!(config, :tool_timeout),
      bash_timeout: Map.fetch!(config, :bash_timeout),
      om_enabled: Map.get(om_config, :enabled, true),
      om_observer_model: Map.get(om_config, :observer_model, "claude-haiku-4.5"),
      om_reflector_model: Map.get(om_config, :reflector_model, "claude-haiku-4.5")
    }
  end
end
