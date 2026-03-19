defmodule Deft.Eval.Skills.InvocationFidelityTest do
  @moduledoc """
  Skill invocation fidelity evals per specs/evals/skills.md section 8.2.

  Tests whether the agent correctly invokes skills via use_skill tool and follows
  the multi-step instructions in the skill definition.
  Pass rate: 85% over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Baselines
  alias Deft.Eval.ResultStore
  alias Deft.Message.Text

  @moduletag :eval
  @moduletag :expensive
  @moduletag timeout: 600_000

  @fixtures_dir "test/eval/fixtures/skills"
  @iterations 20
  @target_pass_rate 0.85
  @category "skills.invocation_fidelity"

  setup_all do
    # Load baselines at start
    {:ok, baselines} = Baselines.load()
    %{baselines: baselines}
  end

  describe "skill invocation fidelity" do
    test "agent follows multi-step instructions from skill definition", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "multi_step_skill.json")
      run_invocation_fidelity_eval(fixture_path, baselines)
    end

    test "agent uses use_skill tool correctly", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "use_skill_tool.json")
      run_invocation_fidelity_eval(fixture_path, baselines)
    end

    test "agent follows ordered steps from skill", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "ordered_steps_skill.json")
      run_invocation_fidelity_eval(fixture_path, baselines)
    end
  end

  # Private helpers

  defp run_invocation_fidelity_eval(fixture_path, baselines) do
    {:ok, fixture} = load_fixture(fixture_path)

    # Run the eval N times
    results =
      Enum.map(1..@iterations, fn iteration ->
        IO.puts("  Iteration #{iteration}/#{@iterations}")
        result = evaluate_invocation_fidelity(fixture)
        IO.puts("  Result: #{if result.passed, do: "PASS", else: "FAIL"} - #{result.reason}")
        result
      end)

    # Calculate pass rate
    passes = Enum.count(results, & &1.passed)
    pass_rate = passes / @iterations

    # Generate run ID and store results
    run_id = ResultStore.generate_run_id()
    commit = ResultStore.get_commit_sha()

    failures =
      results
      |> Enum.reject(& &1.passed)
      |> Enum.map(fn result ->
        %{
          fixture: fixture["id"],
          output: result.output,
          reason: result.reason
        }
      end)

    result_data = %{
      run_id: run_id,
      commit: commit,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: get_model_name(),
      category: @category,
      pass_rate: pass_rate,
      iterations: @iterations,
      cost_usd: estimate_cost(results),
      failures: failures
    }

    ResultStore.store(result_data)

    # Update baselines
    updated_baselines =
      Baselines.update(baselines, @category, pass_rate, @iterations, run_id, commit)

    Baselines.save(updated_baselines)

    # Check against baseline
    if Baselines.below_soft_floor?(baselines, @category, pass_rate) do
      baseline = Baselines.get_baseline(baselines, @category)

      IO.warn("""
      REGRESSION DETECTED
      Category: #{@category}
      Current: #{Float.round(pass_rate * 100, 1)}%
      Baseline: #{Float.round(baseline.baseline * 100, 1)}%
      Soft floor: #{Float.round(baseline.soft_floor * 100, 1)}%
      """)
    end

    # Assert pass rate meets target
    assert pass_rate >= @target_pass_rate,
           "Pass rate #{Float.round(pass_rate * 100, 1)}% below target #{@target_pass_rate * 100}%"
  end

  defp evaluate_invocation_fidelity(fixture) do
    # Build system prompt with use_skill tool definition
    system_prompt = build_system_prompt_with_skill(fixture)

    # Convert fixture messages to Deft.Message format
    messages = convert_to_deft_messages(fixture["messages"], system_prompt)

    # Define use_skill tool
    use_skill_tool = %{
      "name" => "use_skill",
      "description" => "Invoke a skill to execute specialized tasks",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the skill to invoke"
          }
        },
        "required" => ["name"]
      }
    }

    # Call provider with use_skill tool
    case call_provider_with_tools_sync(messages, [use_skill_tool]) do
      {:ok, response_data} ->
        # Check if agent used use_skill tool correctly and followed steps
        judge_result = judge_invocation_fidelity(response_data, fixture)

        %{
          passed: judge_result.passed,
          output: inspect(response_data, pretty: true),
          reason: judge_result.reason
        }

      {:error, reason} ->
        %{
          passed: false,
          output: "",
          reason: "Provider call failed: #{inspect(reason)}"
        }
    end
  end

  defp judge_invocation_fidelity(response_data, fixture) do
    skill_def = fixture["skill_definition"]
    expected_steps = fixture["expected_steps"] || []

    # Check if use_skill tool was called
    tool_uses = response_data[:tool_uses] || []
    use_skill_calls = Enum.filter(tool_uses, fn tu -> tu.name == "use_skill" end)

    cond do
      # If fixture expects use_skill to be called but it wasn't
      fixture["should_invoke_use_skill"] == true and use_skill_calls == [] ->
        %{
          passed: false,
          reason: "Agent did not invoke use_skill tool when it should have"
        }

      # If we're testing that agent follows injected skill definition
      skill_def != nil ->
        # Use LLM-as-judge to check if agent followed the skill steps
        judge_with_llm_for_steps(response_data[:text] || "", expected_steps, skill_def)

      # If we're just testing that use_skill was called correctly
      true ->
        if length(use_skill_calls) > 0 do
          %{passed: true, reason: "Agent correctly used use_skill tool"}
        else
          %{passed: true, reason: "Test passed (no specific requirements)"}
        end
    end
  end

  defp judge_with_llm_for_steps(response_text, expected_steps, skill_definition) do
    # LLM-as-judge prompt to check if agent followed the steps
    judge_prompt = """
    Evaluate whether the agent followed the multi-step instructions from the skill definition.

    Skill definition:
    #{skill_definition}

    Expected steps that should be followed in order:
    #{Enum.map_join(expected_steps, "\n", fn step -> "- #{step}" end)}

    Agent response:
    #{response_text}

    Question: Did the agent follow the steps from the skill definition in order? Did it execute each step as specified?

    Answer with PASS or FAIL followed by a brief reason.
    """

    judge_message = %Deft.Message{
      id: generate_message_id(),
      role: :user,
      content: [%Text{text: judge_prompt}],
      timestamp: DateTime.utc_now()
    }

    case call_provider_sync([judge_message]) do
      {:ok, judgment} ->
        passed = String.contains?(String.upcase(judgment), "PASS")

        %{
          passed: passed,
          reason: String.trim(judgment)
        }

      {:error, reason} ->
        %{
          passed: false,
          reason: "LLM judge failed: #{inspect(reason)}"
        }
    end
  end

  defp call_provider_with_tools_sync(messages, tools) do
    # Use Anthropic provider directly
    provider = Deft.Provider.Anthropic

    config = %{
      model: "claude-sonnet-4-6",
      max_tokens: 2048,
      temperature: 1.0
    }

    case provider.stream(messages, tools, config) do
      {:ok, stream_ref} ->
        collect_stream_response_with_tools(stream_ref)

      {:error, _} = error ->
        error
    end
  end

  defp call_provider_sync(messages) do
    # Use Anthropic provider directly
    provider = Deft.Provider.Anthropic
    tools = []

    config = %{
      model: "claude-sonnet-4-6",
      max_tokens: 1024,
      temperature: 1.0
    }

    case provider.stream(messages, tools, config) do
      {:ok, stream_ref} ->
        collect_stream_response(stream_ref)

      {:error, _} = error ->
        error
    end
  end

  defp collect_stream_response_with_tools(stream_ref) do
    collect_stream_response_with_tools(stream_ref, %{text: "", tool_calls: %{}})
  end

  defp collect_stream_response_with_tools(stream_ref, acc) do
    receive do
      {:provider_event, %Deft.Provider.Event.TextDelta{delta: delta}} ->
        updated_acc = %{acc | text: acc.text <> delta}
        collect_stream_response_with_tools(stream_ref, updated_acc)

      {:provider_event, %Deft.Provider.Event.ToolCallStart{id: id, name: name}} ->
        tool_call = %{id: id, name: name, args_json: ""}
        updated_acc = %{acc | tool_calls: Map.put(acc.tool_calls, id, tool_call)}
        collect_stream_response_with_tools(stream_ref, updated_acc)

      {:provider_event, %Deft.Provider.Event.ToolCallDelta{id: id, delta: delta}} ->
        updated_tool_calls =
          Map.update!(acc.tool_calls, id, fn tc ->
            %{tc | args_json: tc.args_json <> delta}
          end)

        updated_acc = %{acc | tool_calls: updated_tool_calls}
        collect_stream_response_with_tools(stream_ref, updated_acc)

      {:provider_event, %Deft.Provider.Event.ToolCallDone{id: id, args: args}} ->
        updated_tool_calls =
          Map.update!(acc.tool_calls, id, fn tc ->
            %{tc | args: args}
          end)

        updated_acc = %{acc | tool_calls: updated_tool_calls}
        collect_stream_response_with_tools(stream_ref, updated_acc)

      {:provider_event, %Deft.Provider.Event.Done{}} ->
        tool_uses = Map.values(acc.tool_calls)
        {:ok, %{text: acc.text, tool_uses: tool_uses}}

      {:provider_event, %Deft.Provider.Event.Error{message: message}} ->
        {:error, message}

      # Ignore other events
      {:provider_event, _other} ->
        collect_stream_response_with_tools(stream_ref, acc)
    after
      60_000 ->
        {:error, :timeout}
    end
  end

  defp collect_stream_response(stream_ref) do
    collect_stream_response(stream_ref, "")
  end

  defp collect_stream_response(stream_ref, acc) do
    receive do
      {:provider_event, %Deft.Provider.Event.TextDelta{delta: delta}} ->
        collect_stream_response(stream_ref, acc <> delta)

      {:provider_event, %Deft.Provider.Event.Done{}} ->
        {:ok, acc}

      {:provider_event, %Deft.Provider.Event.Error{message: message}} ->
        {:error, message}

      # Ignore other events
      {:provider_event, _other} ->
        collect_stream_response(stream_ref, acc)
    after
      60_000 ->
        {:error, :timeout}
    end
  end

  defp convert_to_deft_messages(fixture_messages, system_prompt) do
    # Add system message first
    system_message = %Deft.Message{
      id: generate_message_id(),
      role: :system,
      content: [%Text{text: system_prompt}],
      timestamp: DateTime.utc_now()
    }

    # Convert fixture messages to Deft.Message format
    user_messages =
      Enum.map(fixture_messages, fn msg ->
        content =
          Enum.map(msg["content"], fn c ->
            %Text{text: c["text"]}
          end)

        role =
          case msg["role"] do
            "user" -> :user
            "assistant" -> :assistant
            role -> raise "Unknown role: #{role}"
          end

        %Deft.Message{
          id: generate_message_id(),
          role: role,
          content: content,
          timestamp: DateTime.utc_now()
        }
      end)

    [system_message | user_messages]
  end

  defp generate_message_id do
    "msg_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp build_system_prompt_with_skill(fixture) do
    base_prompt = """
    You are Claude, a helpful AI assistant created by Anthropic.
    You help users with coding tasks, answering questions, and providing guidance.
    """

    # If fixture has a skill definition to inject, add it
    if skill_def = fixture["skill_definition"] do
      base_prompt <> "\n\n# Current Skill Instructions\n\n" <> skill_def
    else
      base_prompt
    end
  end

  defp load_fixture(path) do
    case File.read(path) do
      {:ok, content} ->
        Jason.decode(content)

      {:error, reason} ->
        {:error, "Failed to load fixture #{path}: #{inspect(reason)}"}
    end
  end

  defp get_model_name do
    "claude-sonnet-4-6"
  end

  defp estimate_cost(results) do
    # Rough estimate: ~2000 tokens per iteration at $3/1M tokens
    # Higher than suggestion tests due to tool use and skill definitions
    length(results) * 0.006
  end
end
