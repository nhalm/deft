defmodule Deft.Eval.Lead.SteeringTest do
  @moduledoc """
  Eval test for Lead steering quality.

  Tests that the Lead agent provides clear, specific corrections when
  Runner agents produce incorrect output. The Lead should:
  - Identify the specific error (not just say "redo it")
  - Provide clear correction guidance
  - Reference the incorrect output

  Per spec section 6.2: 75% pass rate over 20 iterations.
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  @iterations 20
  @pass_threshold 0.75

  describe "steering quality - LLM judge (75% over 20 iterations)" do
    @tag timeout: 600_000
    test "identifies specific errors and provides clear corrections" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          IO.puts("\n[Iteration #{iteration}/#{@iterations}] Running steering quality test...")

          # Create a fixture with Runner output containing an error
          fixture = create_steering_fixture(iteration)

          # Call LLM to produce steering guidance
          steering = call_lead_steering(fixture)

          # Judge the steering quality
          passes_quality_check = judge_steering_quality(steering, fixture)

          if passes_quality_check do
            IO.puts("  ✓ PASS: Steering meets quality criteria")
          else
            IO.puts("  ✗ FAIL: Steering does not meet quality criteria")
          end

          passes_quality_check
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nLead steering quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Steering quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Creates different Runner output fixtures with specific errors
  defp create_steering_fixture(iteration) do
    fixtures = [
      %{
        task: "Implement password hashing using argon2",
        runner_output: """
        I've implemented password hashing in lib/auth.ex:

        ```elixir
        defmodule MyApp.Auth do
          def hash_password(password) do
            Bcrypt.hash_pwd_salt(password)
          end

          def verify_password(password, hash) do
            Bcrypt.verify_pass(password, hash)
          end
        end
        ```
        """,
        expected_error: "bcrypt instead of argon2"
      },
      %{
        task: "Add rate limiting using Redis",
        runner_output: """
        I've implemented rate limiting in lib/plug/rate_limiter.ex:

        ```elixir
        defmodule MyApp.Plug.RateLimiter do
          def call(conn, _opts) do
            # Using ETS for rate limiting
            :ets.insert(:rate_limits, {conn.remote_ip, System.system_time()})
            conn
          end
        end
        ```
        """,
        expected_error: "ETS instead of Redis"
      },
      %{
        task: "Store user sessions in PostgreSQL",
        runner_output: """
        I've implemented session storage in lib/session.ex:

        ```elixir
        defmodule MyApp.Session do
          def create_session(user_id) do
            # Storing session in a cookie
            session_id = generate_token()
            {:ok, session_id}
          end
        end
        ```
        """,
        expected_error: "cookie instead of PostgreSQL"
      },
      %{
        task: "Return 429 status code when rate limit exceeded",
        runner_output: """
        I've updated the rate limiter to return errors:

        ```elixir
        defmodule MyApp.Plug.RateLimiter do
          def call(conn, _opts) do
            if rate_limit_exceeded?(conn) do
              conn
              |> put_status(403)
              |> halt()
            else
              conn
            end
          end
        end
        ```
        """,
        expected_error: "403 instead of 429"
      }
    ]

    # Cycle through fixtures
    fixture_index = rem(iteration - 1, length(fixtures))
    Enum.at(fixtures, fixture_index)
  end

  # Calls the Lead's steering logic via LLM
  defp call_lead_steering(fixture) do
    prompt = """
    You are the Lead agent in an AI coding system. A Runner agent has completed
    a task, but the output contains an error. Your job is to provide clear,
    specific steering to correct the error.

    ## Original Task
    #{fixture.task}

    ## Runner Output
    #{fixture.runner_output}

    ## Your Output

    Provide steering feedback in JSON format with this structure:

    ```json
    {
      "error_identified": "Specific description of what is wrong",
      "correction": "Clear guidance on how to fix it",
      "references_output": true
    }
    ```

    Requirements:
    - Identify the SPECIFIC error (don't just say "redo it" or "fix it")
    - Provide CLEAR correction guidance (what needs to change and why)
    - Reference the incorrect part of the Runner's output
    - Be constructive and actionable

    Output ONLY the JSON, nothing else.
    """

    case Helpers.call_llm_judge(prompt, %{timeout: 60_000}) do
      {:ok, response} ->
        # Extract JSON from response
        parse_steering_json(response)

      {:error, reason} ->
        IO.puts("    LLM error: #{inspect(reason)}")
        %{"error_identified" => "", "correction" => ""}
    end
  end

  # Parse JSON from LLM response
  defp parse_steering_json(response) do
    # Try to extract JSON block
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n```/s, response) do
        [_, json] -> json
        nil -> response
      end

    case Jason.decode(json_str) do
      {:ok, steering} -> steering
      {:error, _} -> %{"error_identified" => "", "correction" => ""}
    end
  end

  # Judge the steering quality using criteria from spec section 6.2
  defp judge_steering_quality(steering, fixture) do
    error_identified = Map.get(steering, "error_identified", "")
    correction = Map.get(steering, "correction", "")

    # Check 1: Error identification is specific (not vague)
    error_is_specific =
      String.length(String.trim(error_identified)) > 20 and
        not vague_error?(error_identified)

    # Check 2: Correction is clear and actionable
    correction_is_clear = String.length(String.trim(correction)) > 30

    # Check 3: Steering identifies the actual error type
    identifies_actual_error =
      String.downcase(error_identified) =~ String.downcase(fixture.expected_error) or
        String.downcase(correction) =~ String.downcase(fixture.expected_error)

    # All checks must pass
    result = error_is_specific and correction_is_clear and identifies_actual_error

    unless result do
      IO.puts("    Quality check details:")
      IO.puts("      - Error is specific: #{error_is_specific}")
      IO.puts("      - Correction is clear: #{correction_is_clear}")

      IO.puts(
        "      - Identifies actual error (#{fixture.expected_error}): #{identifies_actual_error}"
      )

      IO.puts("      - Error identified: #{String.slice(error_identified, 0..100)}")
      IO.puts("      - Correction: #{String.slice(correction, 0..100)}")
    end

    result
  end

  # Check if error description is too vague
  defp vague_error?(error_text) do
    vague_phrases = [
      "redo it",
      "fix it",
      "wrong",
      "incorrect",
      "doesn't work",
      "not right",
      "needs work",
      "try again"
    ]

    downcase = String.downcase(error_text)

    Enum.any?(vague_phrases, fn phrase ->
      downcase == phrase
    end)
  end
end
