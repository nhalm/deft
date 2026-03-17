defmodule Deft.Eval.Skills.SuggestionTest do
  @moduledoc """
  Skill suggestion evals per specs/evals/skills.md section 8.1.

  Tests whether the agent suggests appropriate skills when contextually relevant.
  Pass rate: 80% over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Config
  alias Deft.Eval.Baselines
  alias Deft.Eval.ResultStore
  alias Deft.Message.Text

  @moduletag :eval
  @moduletag :expensive
  @moduletag timeout: 600_000

  @fixtures_dir "test/eval/fixtures/skills"
  @iterations 20
  @target_pass_rate 0.80
  @category "skills.suggestion"

  setup_all do
    # Load baselines at start
    {:ok, baselines} = Baselines.load()
    %{baselines: baselines}
  end

  describe "skill suggestion" do
    test "suggests commit or review when user indicates code is ready", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "commit_ready.json")
      run_suggestion_eval(fixture_path, baselines)
    end

    test "suggests deploy-check when user asks about deployment readiness", %{
      baselines: baselines
    } do
      fixture_path = Path.join(@fixtures_dir, "deployment_readiness.json")
      run_suggestion_eval(fixture_path, baselines)
    end

    test "suggests review when user discusses code quality", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "code_quality.json")
      run_suggestion_eval(fixture_path, baselines)
    end

    test "does not suggest skills for normal coding work", %{baselines: baselines} do
      fixture_path = Path.join(@fixtures_dir, "normal_coding.json")
      run_suggestion_eval(fixture_path, baselines)
    end
  end

  # Private helpers

  defp run_suggestion_eval(fixture_path, baselines) do
    {:ok, fixture} = load_fixture(fixture_path)

    # Run the eval N times
    results =
      Enum.map(1..@iterations, fn iteration ->
        IO.puts("  Iteration #{iteration}/#{@iterations}")
        result = evaluate_suggestion(fixture)
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

  defp evaluate_suggestion(fixture) do
    # Build system prompt with available skills
    skills_listing = build_skills_listing(fixture["available_skills"])

    # Build full system prompt
    system_prompt = build_base_system_prompt() <> "\n\n" <> skills_listing

    # Convert fixture messages to Deft.Message format
    messages = convert_to_deft_messages(fixture["messages"], system_prompt)

    # Call provider via streaming and collect response
    case call_provider_sync(messages) do
      {:ok, response_text} ->
        # Check if response suggests appropriate skills
        expected_suggestions = fixture["expected_suggestion"] || []

        judge_result =
          judge_suggestion(response_text, expected_suggestions, fixture["available_skills"])

        %{
          passed: judge_result.passed,
          output: response_text,
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

  defp judge_suggestion(response, expected_suggestions, available_skills) do
    cond do
      # Case 1: No suggestion expected (normal coding work)
      expected_suggestions == [] ->
        # Check that response doesn't spam skill suggestions
        mentioned_skills =
          available_skills
          |> Enum.filter(fn skill ->
            String.contains?(response, "/#{skill["name"]}")
          end)

        if mentioned_skills == [] do
          %{passed: true, reason: "Correctly avoided suggesting skills for normal work"}
        else
          %{
            passed: false,
            reason:
              "Incorrectly suggested skills: #{Enum.map_join(mentioned_skills, ", ", & &1["name"])}"
          }
        end

      # Case 2: Specific skills expected
      true ->
        # Check if any of the expected skills are mentioned
        mentioned_expected =
          Enum.any?(expected_suggestions, fn skill_name ->
            String.contains?(response, "/#{skill_name}")
          end)

        if mentioned_expected do
          %{passed: true, reason: "Correctly suggested relevant skill"}
        else
          # Use LLM-as-judge as fallback
          judge_with_llm(response, expected_suggestions, available_skills)
        end
    end
  end

  defp judge_with_llm(response, expected_suggestions, available_skills) do
    # LLM-as-judge prompt per spec
    judge_prompt = """
    Evaluate whether the assistant's response appropriately suggests a relevant skill.

    Available skills: #{Enum.map_join(available_skills, ", ", fn s -> "#{s["name"]} (#{s["description"]})" end)}

    Expected suggestions (at least one of): #{Enum.join(expected_suggestions, ", ")}

    Assistant response:
    #{response}

    Question: Does the response suggest a relevant available skill? Is the suggestion appropriate for the conversational context?

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

  defp build_skills_listing(available_skills) do
    skills_text =
      Enum.map_join(available_skills, "\n", fn skill ->
        "- /#{skill["name"]} — #{skill["description"]}"
      end)

    """
    Available skills:
    #{skills_text}

    You can suggest skills when contextually appropriate by mentioning them with their slash command name.
    """
  end

  defp build_test_config do
    %{
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      temperature: 1.0,
      api_key: System.get_env("ANTHROPIC_API_KEY") || raise("ANTHROPIC_API_KEY not set"),
      cache_active: false
    }
  end

  defp extract_text_from_response(response) do
    response.content
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join("\n", & &1.text)
  end

  defp build_base_system_prompt do
    """
    You are Claude, a helpful AI assistant created by Anthropic.
    You help users with coding tasks, answering questions, and providing guidance.
    """
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
    # Rough estimate: ~1000 tokens per iteration at $3/1M tokens
    # This is a placeholder - real cost tracking would parse usage from API responses
    length(results) * 0.003
  end
end
