defmodule Deft.Eval.Lead.TaskPlanningTest do
  @moduledoc """
  Eval test for Lead task decomposition quality.

  Tests that a Lead can:
  - Decompose a deliverable into 4-8 concrete tasks
  - Order tasks by dependencies
  - Define clear done states for each task

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.ResultStore
  alias Deft.Eval.LeadHelpers

  @tag :eval
  @tag :expensive
  @tag timeout: 300_000

  @fixtures_dir "test/eval/fixtures/lead"
  @category "lead.task_planning"
  @iterations 20
  @pass_threshold 0.75

  describe "task decomposition" do
    test "produces 4-8 tasks with dependencies and done states" do
      # Load all fixtures
      fixtures = load_fixtures()
      assert length(fixtures) > 0, "No fixtures found in #{@fixtures_dir}"

      # Run eval iterations
      results =
        Enum.flat_map(fixtures, fn fixture ->
          run_iterations(fixture, @iterations)
        end)

      # Calculate pass rate
      passes = Enum.count(results, fn r -> r.passed end)
      total = length(results)
      pass_rate = passes / total

      # Store results
      run_id = ResultStore.generate_run_id()
      commit = ResultStore.get_commit_sha()

      failures =
        results
        |> Enum.reject(& &1.passed)
        |> Enum.map(fn r ->
          %{
            fixture: r.fixture_id,
            output: r.output,
            reason: r.failure_reason
          }
        end)

      result_data = %{
        run_id: run_id,
        commit: commit,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        model: "claude-sonnet-4-6",
        category: @category,
        pass_rate: pass_rate,
        iterations: total,
        cost_usd: estimate_cost(total),
        failures: failures
      }

      ResultStore.store(result_data)

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             """
             Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{@pass_threshold * 100}%

             Failures: #{length(failures)}/#{total}
             Run ID: #{run_id}
             """
    end
  end

  # Private helpers

  defp load_fixtures do
    case File.ls(@fixtures_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.filter(&String.contains?(&1, "task_planning"))
        |> Enum.map(fn file ->
          path = Path.join(@fixtures_dir, file)
          {:ok, content} = File.read(path)
          {:ok, fixture} = Jason.decode(content, keys: :atoms)
          fixture
        end)

      {:error, _} ->
        []
    end
  end

  defp run_iterations(fixture, n) do
    Enum.map(1..n, fn _iteration ->
      # Build prompt with deliverable and research findings
      prompt = build_lead_planning_prompt(fixture)

      # Call LLM
      config = %{
        model: "claude-sonnet-4-6",
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        max_tokens: 4000
      }

      messages = [
        %{role: "user", content: prompt}
      ]

      case call_llm(config, messages) do
        {:ok, response} ->
          # Validate the response using shared helpers
          validation = validate_task_list(response, fixture.expected_properties)

          %{
            fixture_id: fixture.id,
            passed: validation.passed,
            output: response,
            failure_reason: validation.reason
          }

        {:error, error} ->
          %{
            fixture_id: fixture.id,
            passed: false,
            output: "",
            failure_reason: "LLM call failed: #{inspect(error)}"
          }
      end
    end)
  end

  defp build_lead_planning_prompt(fixture) do
    research_context = format_research_findings(fixture.research_findings)

    """
    You are a Lead managing this deliverable:

    #{fixture.deliverable}

    Your task is to decompose this deliverable into a task list with the following requirements:
    1. Create 4-8 concrete tasks
    2. Order tasks by dependencies (earlier tasks should be foundational, later tasks build on them)
    3. Each task must have a clear done state (how you'll know it's complete)

    #{research_context}

    Output your task list in the following JSON format:
    {
      "tasks": [
        {
          "description": "task description",
          "done_state": "clear completion criteria",
          "depends_on": []
        }
      ]
    }

    The "depends_on" field should list the indices of tasks that must complete before this one (e.g., [0, 1] means depends on first and second tasks).
    """
  end

  defp format_research_findings(findings) do
    sections =
      [
        format_section("Research Findings", Map.get(findings, :research, [])),
        format_section("Interface Contracts", Map.get(findings, :contracts, [])),
        format_section("Decisions", Map.get(findings, :decisions, []))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if sections == "" do
      ""
    else
      """
      ## Context

      #{sections}
      """
    end
  end

  defp format_section(_title, []), do: nil

  defp format_section(title, items) do
    formatted_items =
      items
      |> Enum.map(fn item ->
        "- **#{item.key}**: #{item.value}"
      end)
      |> Enum.join("\n")

    """
    ### #{title}

    #{formatted_items}
    """
  end

  defp call_llm(config, messages) do
    # Use Anthropic provider directly for eval
    api_key = config.api_key || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, "ANTHROPIC_API_KEY not set"}
    else
      request_body = %{
        model: config.model,
        max_tokens: config.max_tokens,
        messages: messages
      }

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]

      case Req.post("https://api.anthropic.com/v1/messages",
             json: request_body,
             headers: headers
           ) do
        {:ok, %{status: 200, body: body}} ->
          # Extract text content from response
          text =
            body["content"]
            |> Enum.find(fn block -> block["type"] == "text" end)
            |> Map.get("text", "")

          {:ok, text}

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp validate_task_list(response, expected) do
    # Try to extract JSON from response
    case LeadHelpers.extract_json(response) do
      {:ok, data} ->
        tasks = Map.get(data, "tasks", [])
        LeadHelpers.validate_tasks(tasks, expected)

      {:error, reason} ->
        %{passed: false, reason: "Failed to parse JSON: #{reason}"}
    end
  end

  defp estimate_cost(iterations) do
    # Rough estimate: $0.015 per iteration (input + output tokens)
    iterations * 0.015
  end
end
