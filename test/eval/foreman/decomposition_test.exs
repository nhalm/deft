defmodule Deft.Eval.Foreman.DecompositionTest do
  use ExUnit.Case, async: false

  alias Deft.Foreman

  # Tag as eval test and skip until Foreman is implemented
  @moduletag :eval
  @moduletag :skip

  @moduledoc """
  Foreman work decomposition evals.

  Tests that Foreman can decompose complex tasks into 1-3 deliverables with:
  - Valid dependency DAG (no circular dependencies)
  - Specific interface contracts
  - Clear deliverable descriptions

  Expected pass rate: 75% over 20 iterations
  Spec: specs/evals/foreman.md section 5.1
  """

  @phoenix_fixture_path "test/eval/fixtures/codebase_snapshots/phoenix-minimal"
  @iterations 20
  @pass_threshold 0.75

  describe "work decomposition" do
    test "decomposes JWT authentication task correctly" do
      results =
        Enum.map(1..@iterations, fn iteration ->
          # Load codebase snapshot
          codebase = load_codebase_snapshot(@phoenix_fixture_path)

          # Prompt: realistic authentication task
          prompt = "Add authentication with JWT to this Phoenix app."

          # Call Foreman (interface to be implemented)
          # Expected return: %{deliverables: [...], dag: %{}, cost_estimate: float}
          result = Foreman.decompose(codebase, prompt)

          # Evaluate deliverable count
          deliverable_count_valid = length(result.deliverables) in 1..3

          # Evaluate DAG validity (no circular dependencies)
          dag_valid = validate_dag(result.dag)

          # Evaluate contract specificity
          contracts_specific = evaluate_contract_specificity(result.deliverables)

          # LLM-as-judge: contract buildability
          contracts_buildable = judge_contract_buildability(result.deliverables)

          %{
            iteration: iteration,
            deliverable_count_valid: deliverable_count_valid,
            dag_valid: dag_valid,
            contracts_specific: contracts_specific,
            contracts_buildable: contracts_buildable,
            pass:
              deliverable_count_valid and dag_valid and contracts_specific and
                contracts_buildable
          }
        end)

      pass_count = Enum.count(results, & &1.pass)
      pass_rate = pass_count / @iterations

      # Log results
      IO.puts("\n=== Foreman Decomposition Eval ===")
      IO.puts("Iterations: #{@iterations}")
      IO.puts("Passed: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")
      IO.puts("Threshold: #{Float.round(@pass_threshold * 100, 1)}%")

      # Log failure examples
      failures = Enum.reject(results, & &1.pass)

      if length(failures) > 0 do
        IO.puts("\nFailure breakdown:")

        IO.puts("  Deliverable count: #{Enum.count(failures, &(!&1.deliverable_count_valid))}")

        IO.puts("  DAG validity: #{Enum.count(failures, &(!&1.dag_valid))}")
        IO.puts("  Contract specificity: #{Enum.count(failures, &(!&1.contracts_specific))}")
        IO.puts("  Contract buildability: #{Enum.count(failures, &(!&1.contracts_buildable))}")
      end

      # Assert pass rate meets threshold
      assert pass_rate >= @pass_threshold,
             "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{Float.round(@pass_threshold * 100, 1)}%"
    end
  end

  # Helper: Load codebase snapshot as a map of file paths to content
  defp load_codebase_snapshot(path) do
    Path.wildcard("#{path}/**/*")
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(fn file_path ->
      relative_path = Path.relative_to(file_path, path)
      content = File.read!(file_path)
      {relative_path, content}
    end)
    |> Map.new()
  end

  # Helper: Validate DAG has no circular dependencies
  defp validate_dag(dag) do
    # DAG format: %{deliverable_id => [dependency_ids]}
    # Check for cycles using DFS
    all_nodes = Map.keys(dag) ++ (Map.values(dag) |> List.flatten() |> Enum.uniq())

    !has_cycle?(dag, all_nodes)
  end

  defp has_cycle?(dag, nodes) do
    Enum.any?(nodes, fn node ->
      visited = MapSet.new()
      rec_stack = MapSet.new()
      dfs_has_cycle?(dag, node, visited, rec_stack)
    end)
  end

  defp dfs_has_cycle?(dag, node, visited, rec_stack) do
    cond do
      MapSet.member?(rec_stack, node) ->
        true

      MapSet.member?(visited, node) ->
        false

      true ->
        visited = MapSet.put(visited, node)
        rec_stack = MapSet.put(rec_stack, node)

        dependencies = Map.get(dag, node, [])

        if Enum.any?(dependencies, &dfs_has_cycle?(dag, &1, visited, rec_stack)) do
          true
        else
          false
        end
    end
  end

  # Helper: Evaluate contract specificity
  # Contracts should mention specific endpoints, data shapes, or function signatures
  defp evaluate_contract_specificity(deliverables) do
    Enum.all?(deliverables, fn deliverable ->
      contract = Map.get(deliverable, :contract, "")

      # Look for specificity markers
      has_endpoint = String.contains?(contract, ["/", "POST", "GET", "PUT", "DELETE"])
      has_data_shape = String.contains?(contract, ["{", "}", "field", "schema", "struct"])

      has_function_sig =
        String.contains?(contract, ["def ", "defp ", "function", "returns", "params"])

      has_endpoint or has_data_shape or has_function_sig
    end)
  end

  # Helper: LLM-as-judge for contract buildability
  # Score 1-5: "Could the downstream Lead build against this contract without asking follow-up questions?"
  defp judge_contract_buildability(_deliverables) do
    # This would use Tribunal's LLM-as-judge in real implementation
    # For now, stub returns true (will be implemented when Foreman exists)

    # Expected implementation:
    # contracts_text = Enum.map_join(deliverables, "\n\n", & &1.contract)
    # prompt = """
    # Rate the following interface contracts on buildability (1-5).
    # Score 5 if a downstream developer could build against these contracts without asking questions.
    # Score 1 if the contracts are vague or missing critical details.
    #
    # Contracts:
    # #{contracts_text}
    #
    # Respond with just a number 1-5.
    # """
    # score = call_llm_judge(prompt)
    # score >= 4

    true
  end
end
