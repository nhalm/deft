defmodule Deft.Eval.Foreman.ConstraintPropagationTest do
  @moduledoc """
  Eval test for Foreman constraint propagation.

  Tests that constraints from the original issue (like "Use argon2" or
  "Don't modify User schema") are correctly propagated from the issue
  to the Lead's steering instructions.

  Per spec section 5.3: 85% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  @iterations 20
  @pass_threshold 0.85

  describe "constraint propagation - LLM judge (85% over 20 iterations)" do
    @tag timeout: 600_000
    test "propagates constraints from issue to Lead steering" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts(
            "\n[Iteration #{iteration}/#{@iterations}] Running constraint propagation test..."
          )

          # Create a fixture with explicit constraints
          fixture = create_constraint_fixture(iteration)

          # Generate steering instructions
          steering = call_foreman_constraint_propagation(fixture)

          # Judge if all constraints are present in steering
          passes_propagation = judge_constraint_propagation(fixture, steering)

          if passes_propagation do
            IO.puts("  ✓ PASS: All constraints propagated to steering")
          else
            IO.puts("  ✗ FAIL: Some constraints missing from steering")
          end

          passes_propagation
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nForeman constraint propagation: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Constraint propagation below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Creates fixtures with explicit constraints that must be propagated
  defp create_constraint_fixture(iteration) do
    fixtures = [
      %{
        task: "Add password hashing to user registration",
        constraints: [
          "Use argon2 for password hashing",
          "Don't modify the User schema structure",
          "Keep backward compatibility with existing passwords"
        ]
      },
      %{
        task: "Implement API rate limiting",
        constraints: [
          "Use Redis for rate limit storage",
          "Don't add new database migrations",
          "Rate limit must be configurable via environment variables"
        ]
      },
      %{
        task: "Add file upload functionality",
        constraints: [
          "Store files in S3, not local filesystem",
          "Maximum file size 10MB",
          "Only allow image file types (PNG, JPG, GIF)"
        ]
      },
      %{
        task: "Build user search feature",
        constraints: [
          "Use Elasticsearch, not database LIKE queries",
          "Search must be case-insensitive",
          "Include fuzzy matching for typos"
        ]
      }
    ]

    # Cycle through fixtures
    fixture_index = rem(iteration - 1, length(fixtures))
    Enum.at(fixtures, fixture_index)
  end

  # Calls Foreman to generate steering instructions with constraint propagation
  defp call_foreman_constraint_propagation(fixture) do
    prompt = """
    You are the Foreman in an AI coding agent system. You've decomposed a task
    and now need to provide steering instructions to the Lead agent who will
    execute it.

    ## Original Task
    #{fixture.task}

    ## Constraints (MUST be respected)
    #{Enum.map_join(fixture.constraints, "\n", fn c -> "- #{c}" end)}

    ## Your Output

    Generate steering instructions for the Lead agent. These instructions must
    include ALL constraints from the original issue.

    Format your output as JSON:

    ```json
    {
      "steering": "Detailed steering instructions that incorporate all constraints..."
    }
    ```

    The steering field should be a single paragraph that naturally includes all
    the constraints while giving direction to the Lead.

    Output ONLY the JSON, nothing else.
    """

    case Helpers.call_llm_judge(prompt, %{timeout: 60_000}) do
      {:ok, response} ->
        parse_steering_json(response)

      {:error, reason} ->
        IO.puts("    LLM error: #{inspect(reason)}")
        %{"steering" => ""}
    end
  end

  # Parse JSON from LLM response
  defp parse_steering_json(response) do
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n```/s, response) do
        [_, json] -> json
        nil -> response
      end

    case Jason.decode(json_str) do
      {:ok, result} -> result
      {:error, _} -> %{"steering" => ""}
    end
  end

  # Judge if all constraints appear in the steering instructions
  defp judge_constraint_propagation(fixture, steering_result) do
    steering = Map.get(steering_result, "steering", "")
    constraints = fixture.constraints

    # Normalize for comparison (case-insensitive)
    steering_lower = String.downcase(steering)

    # Check each constraint
    results =
      Enum.map(constraints, fn constraint ->
        # Extract key terms from constraint
        key_terms = extract_key_terms(constraint)

        # Check if all key terms appear in steering
        all_terms_present =
          Enum.all?(key_terms, fn term ->
            String.downcase(steering_lower) =~ String.downcase(term)
          end)

        unless all_terms_present do
          IO.puts("    Missing constraint: #{constraint}")
          IO.puts("    Key terms: #{inspect(key_terms)}")
        end

        all_terms_present
      end)

    # All constraints must be propagated
    Enum.all?(results)
  end

  # Extract key terms from a constraint for checking
  defp extract_key_terms(constraint) do
    # Remove common words and extract meaningful terms
    words = String.split(String.downcase(constraint), ~r/\s+/)

    # Keep words that are likely to be significant
    Enum.filter(words, fn word ->
      # Remove very common words
      word not in ["use", "for", "to", "the", "a", "an", "and", "or", "not", "in", "on", "at"] and
        String.length(word) > 2
    end)
    # Take the most significant terms (usually the first few)
    |> Enum.take(3)
  end
end
