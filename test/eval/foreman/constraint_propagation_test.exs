defmodule Deft.Eval.Foreman.ConstraintPropagationTest do
  use ExUnit.Case, async: false

  alias Deft.Foreman

  # Tag as eval test and skip until Foreman is implemented
  @moduletag :eval
  @moduletag :skip

  @moduledoc """
  Foreman constraint propagation evals.

  Tests that constraints from structured issues flow correctly into Lead steering instructions.
  Each constraint in the issue should appear in the Lead's steering instructions.

  Expected pass rate: 85% over 20 iterations
  Spec: specs/evals/foreman.md section 5.3
  """

  @iterations 20
  @pass_threshold 0.85

  # Sample constraints for authentication task
  @auth_constraints [
    "Use argon2 for password hashing",
    "Don't modify the existing User schema",
    "All endpoints must require authentication except /health",
    "JWT tokens should expire after 24 hours"
  ]

  describe "constraint propagation" do
    test "propagates authentication constraints to Lead steering" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          # Create structured issue with constraints
          issue = %{
            id: "AUTH-#{iteration}",
            title: "Add JWT authentication to Phoenix app",
            context: "Users need to authenticate before accessing protected routes",
            acceptance_criteria: [
              "Users can register with email and password",
              "Users can login and receive a JWT token",
              "Protected endpoints reject requests without valid JWT"
            ],
            constraints: @auth_constraints
          }

          # Call Foreman decomposition
          # Expected: Foreman decomposes the issue, generates deliverables, and produces
          # steering instructions for each Lead that include relevant constraints
          result = Foreman.decompose(issue)

          # Extract all steering instructions across all Leads
          all_steering_instructions = extract_steering_instructions(result)

          # Check that each constraint appears in at least one Lead's steering instructions
          constraints_propagated =
            check_constraints_propagated(issue.constraints, all_steering_instructions)

          %{
            iteration: iteration,
            constraints_propagated: constraints_propagated,
            missing_constraints:
              find_missing_constraints(issue.constraints, all_steering_instructions),
            pass: constraints_propagated
          }
        end)

      pass_count = Enum.count(results, & &1.pass)
      pass_rate = pass_count / @iterations

      # Log results
      IO.puts("\n=== Foreman Constraint Propagation Eval ===")
      IO.puts("Iterations: #{@iterations}")
      IO.puts("Passed: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("Threshold: #{Float.round(@pass_threshold * 100, 1)}%")

      # Log failure examples
      failures = Enum.reject(results, & &1.pass)

      if length(failures) > 0 do
        IO.puts("\nFailure examples:")

        failures
        |> Enum.take(3)
        |> Enum.each(fn failure ->
          IO.puts("  Iteration #{failure.iteration}:")
          IO.puts("    Missing constraints: #{inspect(failure.missing_constraints)}")
        end)
      end

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{Float.round(@pass_threshold * 100, 1)}%"
    end

    test "propagates data modeling constraints to Lead steering" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          # Create issue with data modeling constraints
          issue = %{
            id: "DATA-#{iteration}",
            title: "Add user profile management",
            context: "Users need to update their profile information",
            acceptance_criteria: [
              "Users can view their profile",
              "Users can update their name, bio, and avatar"
            ],
            constraints: [
              "Profile data must be stored in a separate profiles table",
              "Avatar URLs must be validated before saving",
              "Bio field has a 500 character limit"
            ]
          }

          result = Foreman.decompose(issue)
          all_steering_instructions = extract_steering_instructions(result)

          constraints_propagated =
            check_constraints_propagated(issue.constraints, all_steering_instructions)

          %{
            iteration: iteration,
            constraints_propagated: constraints_propagated,
            missing_constraints:
              find_missing_constraints(issue.constraints, all_steering_instructions),
            pass: constraints_propagated
          }
        end)

      pass_count = Enum.count(results, & &1.pass)
      pass_rate = pass_count / @iterations

      # Log results
      IO.puts("\n=== Foreman Constraint Propagation (Data Modeling) Eval ===")
      IO.puts("Iterations: #{@iterations}")
      IO.puts("Passed: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("Threshold: #{Float.round(@pass_threshold * 100, 1)}%")

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{Float.round(@pass_threshold * 100, 1)}%"
    end
  end

  # Helper: Extract steering instructions from all Leads in the decomposition result
  defp extract_steering_instructions(result) do
    # Expected format: %{deliverables: [...], dag: %{}, cost_estimate: float}
    # Each deliverable should have a :steering field containing instructions for that Lead
    result.deliverables
    |> Enum.flat_map(fn deliverable ->
      steering = Map.get(deliverable, :steering, "")
      [steering]
    end)
    |> Enum.join("\n")
  end

  # Helper: Check if all constraints appear in the steering instructions
  defp check_constraints_propagated(constraints, steering_instructions) do
    Enum.all?(constraints, fn constraint ->
      # Check if the constraint (or a close paraphrase) appears in steering
      # For simplicity, we check for key terms from the constraint
      constraint_appears?(constraint, steering_instructions)
    end)
  end

  # Helper: Find which constraints are missing from steering instructions
  defp find_missing_constraints(constraints, steering_instructions) do
    Enum.reject(constraints, fn constraint ->
      constraint_appears?(constraint, steering_instructions)
    end)
  end

  # Helper: Check if a constraint appears in the steering instructions
  defp constraint_appears?(constraint, steering_instructions) do
    # Normalize strings for comparison
    normalized_constraint = String.downcase(constraint)
    normalized_steering = String.downcase(steering_instructions)

    # Extract key terms from constraint (words longer than 3 characters)
    key_terms =
      normalized_constraint
      |> String.split(~r/\W+/)
      |> Enum.filter(&(String.length(&1) > 3))
      |> Enum.reject(&(&1 in ["must", "should", "need", "have", "with", "from", "that", "this"]))

    # Check if at least 60% of key terms appear in steering
    if length(key_terms) == 0 do
      # No key terms to check, consider it propagated if constraint is very short
      String.length(constraint) < 10
    else
      matches = Enum.count(key_terms, &String.contains?(normalized_steering, &1))
      match_rate = matches / length(key_terms)
      match_rate >= 0.6
    end
  end
end
