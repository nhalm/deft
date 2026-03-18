defmodule Deft.Eval.Lead.SteeringTest do
  @moduledoc """
  Eval test for Lead steering quality.

  Tests that a Lead can:
  - Identify specific errors in Runner output
  - Provide clear, actionable corrections
  - Avoid vague instructions like "redo it"

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.ResultStore
  alias Deft.Eval.LeadHelpers

  @tag :eval
  @tag :expensive
  @tag timeout: 300_000

  @fixtures_dir "test/eval/fixtures/lead"
  @category "lead.steering"
  @iterations 20
  @pass_threshold 0.75

  describe "steering quality" do
    test "identifies errors and provides specific corrections" do
      # Load all steering fixtures
      fixtures = load_fixtures()
      assert length(fixtures) > 0, "No steering fixtures found in #{@fixtures_dir}"

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
        |> Enum.filter(&String.contains?(&1, "steering"))
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
      # Build prompt with runner output and expected correction
      prompt = build_steering_prompt(fixture)

      # Call LLM
      config = %{
        model: "claude-sonnet-4-6",
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        max_tokens: 2000
      }

      messages = [
        %{role: "user", content: prompt}
      ]

      case call_llm(config, messages) do
        {:ok, response} ->
          # Validate the steering response
          validation = validate_steering(response, fixture)

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

  defp build_steering_prompt(fixture) do
    """
    You are a Lead agent managing a Runner that has just completed a task.

    The Runner was asked to: #{fixture.task_description}

    The Runner produced the following output:

    #{fixture.runner_output}

    Review the Runner's output and identify any issues. If there are errors:
    1. Identify the SPECIFIC error (don't just say "fix it" or "redo it")
    2. Provide a CLEAR correction explaining what needs to change

    If the output is correct, acknowledge it.

    Provide your response in JSON format:
    {
      "has_error": true/false,
      "error_identified": "specific description of what's wrong",
      "correction": "clear actionable instruction on what to change"
    }

    If there's no error, set has_error to false and the other fields can be empty strings.
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

  defp validate_steering(response, fixture) do
    # Try to extract JSON from response
    case LeadHelpers.extract_json(response) do
      {:ok, data} ->
        has_error = Map.get(data, "has_error", false)
        error_identified = Map.get(data, "error_identified", "")
        correction = Map.get(data, "correction", "")

        cond do
          # Check if error detection matches expectation
          has_error != fixture.has_error ->
            %{
              passed: false,
              reason: "Error detection mismatch: expected #{fixture.has_error}, got #{has_error}"
            }

          # If there should be an error, validate the response quality
          has_error ->
            validate_error_correction(error_identified, correction, fixture)

          # No error expected and none found - pass
          true ->
            %{passed: true, reason: nil}
        end

      {:error, reason} ->
        %{passed: false, reason: "Failed to parse JSON: #{reason}"}
    end
  end

  defp validate_error_correction(error_identified, correction, fixture) do
    # Check that error identification is specific (mentions the actual problem)
    error_is_specific =
      fixture.required_error_mentions
      |> Enum.any?(fn keyword ->
        String.downcase(error_identified) =~ String.downcase(keyword)
      end)

    # Check that correction is actionable (not vague like "fix it" or "redo")
    vague_phrases = ["fix it", "redo it", "try again", "do it again", "incorrect"]

    correction_is_specific =
      String.length(correction) > 20 and
        not Enum.any?(vague_phrases, fn phrase ->
          String.downcase(correction) == String.downcase(phrase) or
            (String.length(correction) < 30 and
               String.downcase(correction) =~ String.downcase(phrase))
        end)

    # Check that correction mentions the expected solution
    correction_has_solution =
      fixture.required_correction_mentions
      |> Enum.any?(fn keyword ->
        String.downcase(correction) =~ String.downcase(keyword)
      end)

    cond do
      not error_is_specific ->
        %{
          passed: false,
          reason:
            "Error identification not specific enough. Expected mention of: #{inspect(fixture.required_error_mentions)}"
        }

      not correction_is_specific ->
        %{passed: false, reason: "Correction too vague or generic"}

      not correction_has_solution ->
        %{
          passed: false,
          reason:
            "Correction doesn't mention expected solution: #{inspect(fixture.required_correction_mentions)}"
        }

      true ->
        %{passed: true, reason: nil}
    end
  end

  defp estimate_cost(iterations) do
    # Rough estimate: $0.01 per iteration (input + output tokens for steering check)
    iterations * 0.01
  end
end
