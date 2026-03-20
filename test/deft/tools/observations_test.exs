defmodule Deft.Tools.ObservationsTest do
  use ExUnit.Case, async: true

  alias Deft.Tools.Observations
  alias Deft.Tool.Context
  alias Deft.Message.Text

  setup do
    session_id = "test-observations-#{:rand.uniform(100_000)}"

    # Start OM.State with some observations
    config = %Deft.Config{
      model: "claude-sonnet-4",
      provider: "anthropic",
      turn_limit: 25,
      tool_timeout: 120_000,
      bash_timeout: 120_000,
      om_enabled: true,
      om_observer_model: "claude-haiku-4.5",
      om_reflector_model: "claude-haiku-4.5",
      om_observer_provider: "anthropic",
      om_reflector_provider: "anthropic",
      om_observer_temperature: 0.0,
      om_reflector_temperature: 0.0,
      om_message_token_threshold: 30_000,
      om_observation_token_threshold: 40_000,
      om_buffer_interval: 0.2,
      om_buffer_tail_retention: 0.2,
      om_hard_threshold_multiplier: 1.2,
      om_previous_observer_tokens: 8_000,
      cache_token_threshold: 10_000,
      cache_token_threshold_read: 20_000,
      cache_token_threshold_grep: 8_000,
      cache_token_threshold_ls: 4_000,
      cache_token_threshold_find: 4_000,
      issues_compaction_days: 90,
      work_cost_ceiling: 50.0,
      job_test_command: "mix test",
      job_keep_failed_branches: false,
      job_squash_on_complete: true,
      job_initial_concurrency: 2,
      job_max_leads: 5,
      job_max_runners_per_lead: 3,
      job_research_timeout: 120_000,
      job_runner_timeout: 300_000,
      job_foreman_model: "claude-sonnet-4",
      job_lead_model: "claude-sonnet-4",
      job_runner_model: "claude-sonnet-4",
      job_research_runner_model: "claude-sonnet-4",
      job_max_duration: 1_800_000
    }

    # Start OM supervisor and state
    {:ok, _om_sup} =
      Deft.OM.Supervisor.start_link(
        session_id: session_id,
        config: config
      )

    # Create tool context
    context = %Context{
      working_dir: File.cwd!(),
      session_id: session_id,
      emit: fn _ -> :ok end,
      bash_timeout: 120_000
    }

    on_exit(fn ->
      # Clean up OM processes
      case Registry.lookup(Deft.ProcessRegistry, {:om_supervisor, session_id}) do
        [{pid, _}] ->
          if Process.alive?(pid) do
            Process.exit(pid, :kill)
          end

        [] ->
          :ok
      end
    end)

    %{context: context, session_id: session_id}
  end

  describe "behaviour implementation" do
    test "implements Deft.Tool behaviour" do
      Code.ensure_loaded!(Deft.Tools.Observations)
      assert function_exported?(Deft.Tools.Observations, :name, 0)
      assert function_exported?(Deft.Tools.Observations, :description, 0)
      assert function_exported?(Deft.Tools.Observations, :parameters, 0)
      assert function_exported?(Deft.Tools.Observations, :execute, 2)
    end

    test "name/0 returns 'observations'" do
      assert Observations.name() == "observations"
    end

    test "description/0 returns a string" do
      description = Observations.description()
      assert is_binary(description)
      assert String.contains?(description, "observational memory")
    end

    test "parameters/0 returns valid schema" do
      params = Observations.parameters()
      assert is_map(params)
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert Map.has_key?(params["properties"], "mode")
      assert Map.has_key?(params["properties"], "search_term")
    end
  end

  describe "execute/2" do
    test "returns empty message when no observations exist", %{context: context} do
      result = Observations.execute(%{}, context)
      assert {:ok, [%Text{text: text}]} = result
      assert text == "No observations yet."
    end

    test "defaults to summary mode when no mode specified", %{context: context} do
      result = Observations.execute(%{}, context)
      assert {:ok, [%Text{text: _text}]} = result
    end

    test "accepts full mode", %{context: context} do
      result = Observations.execute(%{"mode" => "full"}, context)
      assert {:ok, [%Text{text: _text}]} = result
    end

    test "returns error when search mode without search_term", %{context: context} do
      result = Observations.execute(%{"mode" => "search"}, context)
      assert {:error, msg} = result
      assert String.contains?(msg, "search_term")
    end

    test "accepts search mode with search_term", %{context: context} do
      result = Observations.execute(%{"mode" => "search", "search_term" => "test"}, context)
      assert {:ok, [%Text{text: _text}]} = result
    end

    test "returns error for invalid mode", %{context: context} do
      result = Observations.execute(%{"mode" => "invalid"}, context)
      assert {:error, msg} = result
      assert String.contains?(msg, "Invalid mode")
    end
  end
end
