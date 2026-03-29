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
          model: Deft.Provider.model_name(),
          provider: Deft.Provider.provider_name(),
          turn_limit: pos_integer(),
          tool_timeout: pos_integer(),
          bash_timeout: pos_integer(),
          om_enabled: boolean(),
          om_observer_model: Deft.Provider.model_name(),
          om_reflector_model: Deft.Provider.model_name(),
          om_observer_provider: Deft.Provider.provider_name(),
          om_reflector_provider: Deft.Provider.provider_name(),
          om_observer_temperature: float(),
          om_reflector_temperature: float(),
          om_message_token_threshold: pos_integer(),
          om_observation_token_threshold: pos_integer(),
          om_buffer_interval: float(),
          om_buffer_tail_retention: float(),
          om_hard_threshold_multiplier: float(),
          om_previous_observer_tokens: pos_integer(),
          cache_token_threshold: pos_integer(),
          cache_token_threshold_read: pos_integer(),
          cache_token_threshold_grep: pos_integer(),
          cache_token_threshold_ls: pos_integer(),
          cache_token_threshold_find: pos_integer(),
          issues_compaction_days: pos_integer(),
          work_cost_ceiling: float(),
          job_test_command: String.t(),
          job_keep_failed_branches: boolean(),
          job_squash_on_complete: boolean(),
          job_initial_concurrency: pos_integer(),
          job_max_leads: pos_integer(),
          job_max_runners_per_lead: pos_integer(),
          job_research_timeout: pos_integer(),
          job_runner_timeout: pos_integer(),
          job_foreman_model: Deft.Provider.model_name(),
          job_lead_model: Deft.Provider.model_name(),
          job_runner_model: Deft.Provider.model_name(),
          job_research_runner_model: Deft.Provider.model_name(),
          job_max_duration: pos_integer()
        }

  @enforce_keys [
    :model,
    :provider,
    :turn_limit,
    :tool_timeout,
    :bash_timeout,
    :om_enabled,
    :om_observer_model,
    :om_reflector_model,
    :om_observer_provider,
    :om_reflector_provider,
    :om_observer_temperature,
    :om_reflector_temperature,
    :om_message_token_threshold,
    :om_observation_token_threshold,
    :om_buffer_interval,
    :om_buffer_tail_retention,
    :om_hard_threshold_multiplier,
    :om_previous_observer_tokens,
    :cache_token_threshold,
    :cache_token_threshold_read,
    :cache_token_threshold_grep,
    :cache_token_threshold_ls,
    :cache_token_threshold_find,
    :issues_compaction_days,
    :work_cost_ceiling,
    :job_test_command,
    :job_keep_failed_branches,
    :job_squash_on_complete,
    :job_initial_concurrency,
    :job_max_leads,
    :job_max_runners_per_lead,
    :job_research_timeout,
    :job_runner_timeout,
    :job_foreman_model,
    :job_lead_model,
    :job_runner_model,
    :job_research_runner_model,
    :job_max_duration
  ]

  defstruct [
    :model,
    :provider,
    :turn_limit,
    :tool_timeout,
    :bash_timeout,
    :om_enabled,
    :om_observer_model,
    :om_reflector_model,
    :om_observer_provider,
    :om_reflector_provider,
    :om_observer_temperature,
    :om_reflector_temperature,
    :om_message_token_threshold,
    :om_observation_token_threshold,
    :om_buffer_interval,
    :om_buffer_tail_retention,
    :om_hard_threshold_multiplier,
    :om_previous_observer_tokens,
    :cache_token_threshold,
    :cache_token_threshold_read,
    :cache_token_threshold_grep,
    :cache_token_threshold_ls,
    :cache_token_threshold_find,
    :issues_compaction_days,
    :work_cost_ceiling,
    :job_test_command,
    :job_keep_failed_branches,
    :job_squash_on_complete,
    :job_initial_concurrency,
    :job_max_leads,
    :job_max_runners_per_lead,
    :job_research_timeout,
    :job_runner_timeout,
    :job_foreman_model,
    :job_lead_model,
    :job_runner_model,
    :job_research_runner_model,
    :job_max_duration
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
        model: "claude-sonnet-4-20250514",
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
  @dialyzer {:nowarn_function, defaults: 0}
  @spec defaults() :: map()
  def defaults do
    %{
      model: "claude-sonnet-4-20250514",
      provider: "anthropic",
      turn_limit: 25,
      tool_timeout: 120_000,
      bash_timeout: 120_000,
      om: %{
        enabled: true,
        observer_model: "claude-haiku-4.5",
        reflector_model: "claude-haiku-4.5",
        observer_provider: "anthropic",
        reflector_provider: "anthropic",
        observer_temperature: 0.0,
        reflector_temperature: 0.0,
        message_token_threshold: 30_000,
        observation_token_threshold: 40_000,
        buffer_interval: 0.2,
        buffer_tail_retention: 0.2,
        hard_threshold_multiplier: 1.2,
        previous_observer_tokens: 8_000
      },
      cache: %{
        token_threshold: 10_000,
        token_threshold_read: 20_000,
        token_threshold_grep: 8_000,
        token_threshold_ls: 4_000,
        token_threshold_find: 4_000
      },
      issues: %{
        compaction_days: 90
      },
      work: %{
        cost_ceiling: 50.0
      },
      job: %{
        test_command: "mix test",
        keep_failed_branches: false,
        squash_on_complete: true,
        initial_concurrency: 2,
        max_leads: 5,
        max_runners_per_lead: 3,
        research_timeout: 120_000,
        runner_timeout: 300_000,
        foreman_model: "claude-sonnet-4-20250514",
        lead_model: "claude-sonnet-4-20250514",
        runner_model: "claude-sonnet-4-20250514",
        research_runner_model: "claude-sonnet-4-20250514",
        max_duration: 1_800_000
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
    Enum.reduce(flags, %{}, &normalize_flag/2)
  end

  # Normalize a single CLI flag
  defp normalize_flag({:om_enabled, value}, acc) do
    Map.update(acc, :om, %{enabled: value}, fn om -> Map.put(om, :enabled, value) end)
  end

  defp normalize_flag({:om_observer_model, value}, acc) do
    Map.update(acc, :om, %{observer_model: value}, fn om ->
      Map.put(om, :observer_model, value)
    end)
  end

  defp normalize_flag({:om_reflector_model, value}, acc) do
    Map.update(acc, :om, %{reflector_model: value}, fn om ->
      Map.put(om, :reflector_model, value)
    end)
  end

  defp normalize_flag({:om_observer_provider, value}, acc) do
    Map.update(acc, :om, %{observer_provider: value}, fn om ->
      Map.put(om, :observer_provider, value)
    end)
  end

  defp normalize_flag({:om_reflector_provider, value}, acc) do
    Map.update(acc, :om, %{reflector_provider: value}, fn om ->
      Map.put(om, :reflector_provider, value)
    end)
  end

  defp normalize_flag({:cache_token_threshold, value}, acc) do
    Map.update(acc, :cache, %{token_threshold: value}, fn cache ->
      Map.put(cache, :token_threshold, value)
    end)
  end

  defp normalize_flag({:cache_token_threshold_read, value}, acc) do
    Map.update(acc, :cache, %{token_threshold_read: value}, fn cache ->
      Map.put(cache, :token_threshold_read, value)
    end)
  end

  defp normalize_flag({:cache_token_threshold_grep, value}, acc) do
    Map.update(acc, :cache, %{token_threshold_grep: value}, fn cache ->
      Map.put(cache, :token_threshold_grep, value)
    end)
  end

  defp normalize_flag({:cache_token_threshold_ls, value}, acc) do
    Map.update(acc, :cache, %{token_threshold_ls: value}, fn cache ->
      Map.put(cache, :token_threshold_ls, value)
    end)
  end

  defp normalize_flag({:cache_token_threshold_find, value}, acc) do
    Map.update(acc, :cache, %{token_threshold_find: value}, fn cache ->
      Map.put(cache, :token_threshold_find, value)
    end)
  end

  defp normalize_flag({key, value}, acc) do
    Map.put(acc, key, value)
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
    base_config = %{
      model: Map.fetch!(config, :model),
      provider: Map.fetch!(config, :provider),
      turn_limit: Map.fetch!(config, :turn_limit),
      tool_timeout: Map.fetch!(config, :tool_timeout),
      bash_timeout: Map.fetch!(config, :bash_timeout)
    }

    all_fields =
      base_config
      |> Map.merge(extract_om_config(config))
      |> Map.merge(extract_cache_config(config))
      |> Map.merge(extract_issues_config(config))
      |> Map.merge(extract_work_config(config))
      |> Map.merge(extract_job_config(config))

    struct!(__MODULE__, all_fields)
  end

  # Extract OM config fields
  defp extract_om_config(config) do
    om_config = Map.get(config, :om, %{})

    %{
      om_enabled: Map.get(om_config, :enabled, true),
      om_observer_model: Map.get(om_config, :observer_model, "claude-haiku-4.5"),
      om_reflector_model: Map.get(om_config, :reflector_model, "claude-haiku-4.5"),
      om_observer_provider: Map.get(om_config, :observer_provider, "anthropic"),
      om_reflector_provider: Map.get(om_config, :reflector_provider, "anthropic"),
      om_observer_temperature: Map.get(om_config, :observer_temperature, 0.0),
      om_reflector_temperature: Map.get(om_config, :reflector_temperature, 0.0),
      om_message_token_threshold: Map.get(om_config, :message_token_threshold, 30_000),
      om_observation_token_threshold: Map.get(om_config, :observation_token_threshold, 40_000),
      om_buffer_interval: Map.get(om_config, :buffer_interval, 0.2),
      om_buffer_tail_retention: Map.get(om_config, :buffer_tail_retention, 0.2),
      om_hard_threshold_multiplier: Map.get(om_config, :hard_threshold_multiplier, 1.2),
      om_previous_observer_tokens: Map.get(om_config, :previous_observer_tokens, 8_000)
    }
  end

  # Extract cache config fields
  defp extract_cache_config(config) do
    cache_config = Map.get(config, :cache, %{})

    %{
      cache_token_threshold: Map.get(cache_config, :token_threshold, 10_000),
      cache_token_threshold_read: Map.get(cache_config, :token_threshold_read, 20_000),
      cache_token_threshold_grep: Map.get(cache_config, :token_threshold_grep, 8_000),
      cache_token_threshold_ls: Map.get(cache_config, :token_threshold_ls, 4_000),
      cache_token_threshold_find: Map.get(cache_config, :token_threshold_find, 4_000)
    }
  end

  # Extract issues config fields
  defp extract_issues_config(config) do
    issues_config = Map.get(config, :issues, %{})

    %{
      issues_compaction_days: Map.get(issues_config, :compaction_days, 90)
    }
  end

  # Extract work config fields
  defp extract_work_config(config) do
    work_config = Map.get(config, :work, %{})

    %{
      work_cost_ceiling: Map.get(work_config, :cost_ceiling, 50.0)
    }
  end

  # Extract job config fields
  defp extract_job_config(config) do
    job_config = Map.get(config, :job, %{})

    %{
      job_test_command: Map.get(job_config, :test_command, "mix test"),
      job_keep_failed_branches: Map.get(job_config, :keep_failed_branches, false),
      job_squash_on_complete: Map.get(job_config, :squash_on_complete, true),
      job_initial_concurrency: Map.get(job_config, :initial_concurrency, 2),
      job_max_leads: Map.get(job_config, :max_leads, 5),
      job_max_runners_per_lead: Map.get(job_config, :max_runners_per_lead, 3),
      job_research_timeout: Map.get(job_config, :research_timeout, 120_000),
      job_runner_timeout: Map.get(job_config, :runner_timeout, 300_000),
      job_foreman_model: Map.get(job_config, :foreman_model, "claude-sonnet-4-20250514"),
      job_lead_model: Map.get(job_config, :lead_model, "claude-sonnet-4-20250514"),
      job_runner_model: Map.get(job_config, :runner_model, "claude-sonnet-4-20250514"),
      job_research_runner_model:
        Map.get(job_config, :research_runner_model, "claude-sonnet-4-20250514"),
      job_max_duration: Map.get(job_config, :max_duration, 1_800_000)
    }
  end
end
