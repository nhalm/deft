defmodule Deft.Eval.Spilling.CacheRetrievalTest do
  @moduledoc """
  Cache Retrieval Behavior Eval

  Tests whether the agent correctly uses cache_read when a spilled tool result
  summary doesn't contain enough detail for the task at hand.

  Spec: evals/spilling.md section 7.2
  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.Message
  alias Deft.Message.Text
  alias Deft.Store
  alias Deft.Tool.Context
  alias Deft.Provider.Anthropic

  @moduletag timeout: :infinity

  @iterations 20
  @pass_threshold 0.85

  describe "cache retrieval behavior" do
    @describetag :eval
    @describetag :expensive
    @describetag :integration

    test "agent uses cache_read when summary lacks required detail" do
      # Run the eval N times and collect results
      results =
        for iteration <- 1..@iterations do
          result = run_single_iteration(iteration)

          IO.puts(
            "  Iteration #{iteration}/#{@iterations}: #{if result, do: "PASS", else: "FAIL"}"
          )

          result
        end

      # Calculate pass rate
      passed = Enum.count(results, & &1)
      pass_rate = passed / @iterations

      IO.puts("\n=== Cache Retrieval Eval Results ===")
      IO.puts("Passed: #{passed}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("Threshold: #{Float.round(@pass_threshold * 100, 1)}%")

      assert pass_rate >= @pass_threshold,
             "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{Float.round(@pass_threshold * 100, 1)}%"
    end
  end

  # Run a single iteration of the eval
  defp run_single_iteration(iteration) do
    # Create temporary directory for this iteration
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cache_retrieval_eval_#{iteration}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    try do
      # Set up cache with spilled result
      session_id = "eval-session-#{iteration}"
      {cache_key, cache_pid} = setup_cache_with_spilled_result(session_id, tmp_dir)

      # Create agent configuration
      config = %{
        provider: Anthropic,
        model: "claude-sonnet-4-6",
        turn_limit: 10,
        om_enabled: false,
        cache_config: %{
          "default" => 4000,
          "grep" => 4000,
          "read" => 8000
        }
      }

      # Create initial context with spilled result summary
      base_time = DateTime.utc_now()

      initial_messages = [
        %Message{
          id: "msg_1",
          role: :user,
          timestamp: base_time,
          content: [
            %Text{
              text: """
              I need to find the email address for the user named "Alice Johnson" in the system.
              I already ran a grep search earlier.
              """
            }
          ]
        },
        %Message{
          id: "msg_2",
          role: :assistant,
          timestamp: DateTime.add(base_time, 1, :second),
          content: [
            %Text{
              text:
                "I'll check the grep results from your earlier search. Let me use the grep tool to find user information."
            }
          ]
        },
        %Message{
          id: "msg_3",
          role: :assistant,
          timestamp: DateTime.add(base_time, 2, :second),
          content: [
            %Deft.Message.ToolUse{
              id: "tool_1",
              name: "grep",
              args: %{"pattern" => "user", "path" => "."}
            }
          ]
        },
        %Message{
          id: "msg_4",
          role: :user,
          timestamp: DateTime.add(base_time, 3, :second),
          content: [
            %Deft.Message.ToolResult{
              tool_use_id: "tool_1",
              name: "grep",
              is_error: false,
              content: """
              Result cached (487 lines, 12,456 chars).

              The search found many user entries across multiple files. Results include user accounts,
              configuration files, and log entries. To get specific details for any user, retrieve
              the full results.

              Full results: cache://#{cache_key}
              """
            }
          ]
        }
      ]

      # Start agent with initial context
      {:ok, agent_pid} =
        Agent.start_link(
          session_id: session_id,
          config: config,
          messages: initial_messages
        )

      # Start monitoring for tool calls before prompting
      monitor_task =
        Task.async(fn ->
          monitor_agent_tool_calls(session_id)
        end)

      # Give monitor task time to subscribe
      Process.sleep(100)

      # Now prompt the agent with the question that requires cache details
      Agent.prompt(agent_pid, "What is Alice Johnson's email address?")

      # Wait for tool calls (with timeout)
      tool_calls =
        case Task.yield(monitor_task, 120_000) || Task.shutdown(monitor_task) do
          {:ok, calls} -> calls
          _ -> []
        end

      # Check if cache_read was called
      cache_read_used = Enum.any?(tool_calls, fn call -> Map.get(call, :name) == "cache_read" end)

      # Clean up
      if Process.alive?(agent_pid), do: GenServer.stop(agent_pid)
      if Process.alive?(cache_pid), do: Store.cleanup(cache_pid)

      cache_read_used
    rescue
      error ->
        IO.puts("  Error in iteration #{iteration}: #{Exception.message(error)}")
        false
    after
      File.rm_rf!(tmp_dir)
    end
  end

  # Set up cache with a spilled grep result
  defp setup_cache_with_spilled_result(session_id, tmp_dir) do
    # Create cache store
    dets_path = Path.join(tmp_dir, "cache.dets")

    {:ok, cache_pid} =
      Store.start_link(
        name: {:cache, session_id, "main"},
        type: :cache,
        dets_path: dets_path
      )

    # Generate a cache key
    cache_key = "grep-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    # Create detailed grep result with user information
    cached_content =
      """
      users.json:15:  "name": "Bob Smith",
      users.json:16:  "email": "bob.smith@example.com",
      users.json:20:  "name": "Alice Johnson",
      users.json:21:  "email": "alice.johnson@company.io",
      users.json:25:  "name": "Charlie Brown",
      users.json:26:  "email": "charlie.brown@test.org",
      config/users.yaml:10:  user_admin: alice_j
      config/users.yaml:15:  user_readonly: bob_s
      logs/activity.log:142: [INFO] User alice_j logged in
      logs/activity.log:156: [INFO] User bob_s accessed report
      database.sql:25: CREATE TABLE users (
      database.sql:26:   user_id INT PRIMARY KEY,
      database.sql:27:   username VARCHAR(255),
      database.sql:28:   email VARCHAR(255)
      """
      |> String.trim()

    # Write to cache
    :ok =
      Store.write(
        cache_pid,
        cache_key,
        cached_content,
        %{tool: "grep", created: System.monotonic_time()}
      )

    {cache_key, cache_pid}
  end

  # Monitor agent for tool calls
  defp monitor_agent_tool_calls(session_id) do
    # Subscribe to agent events via Registry
    Registry.register(Deft.Registry, {:session, session_id}, [])

    # Collect tool calls for up to 120 seconds
    collect_tool_calls([], 120_000)
  end

  # Recursively collect tool calls from agent events
  defp collect_tool_calls(tool_calls, timeout) when timeout > 0 do
    start_time = System.monotonic_time(:millisecond)

    receive do
      {:agent_event, {:tool_call_start, %{name: name} = call}} ->
        remaining = timeout - (System.monotonic_time(:millisecond) - start_time)
        collect_tool_calls([call | tool_calls], remaining)

      {:agent_event, {:state_change, :idle}} ->
        # Agent finished, return collected calls
        Enum.reverse(tool_calls)

      {:agent_event, _other} ->
        remaining = timeout - (System.monotonic_time(:millisecond) - start_time)
        collect_tool_calls(tool_calls, remaining)
    after
      timeout ->
        # Timeout reached, return what we have
        Enum.reverse(tool_calls)
    end
  end

  defp collect_tool_calls(tool_calls, _timeout), do: Enum.reverse(tool_calls)
end
