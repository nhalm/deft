defmodule Mix.Tasks.Eval.ValidateFixtures do
  @moduledoc """
  Validates that all eval fixtures have spec_version fields matching current spec versions.

  Usage:
      mix eval.validate_fixtures [fixtures_dir]

  If no fixtures directory is provided, defaults to:
      test/eval/fixtures

  This task:
  - Scans all .json fixture files in the directory
  - Checks each fixture's spec_version field
  - Compares against the current version of the relevant spec
  - Reports stale fixtures that need updating

  Exit codes:
  - 0: All fixtures valid
  - 1: Stale or invalid fixtures found
  """

  use Mix.Task

  alias Deft.Eval.FixtureValidator

  @shortdoc "Validate that fixture spec_versions match current specs"

  @impl Mix.Task
  def run(args) do
    # Ensure modules are compiled
    Mix.Task.run("compile")

    fixtures_dir =
      case args do
        [dir] -> dir
        [] -> "test/eval/fixtures"
      end

    case FixtureValidator.validate_fixtures(fixtures_dir) do
      {:ok, report} ->
        output = FixtureValidator.format_report(report)
        Mix.shell().info(output)

        if report.stale > 0 or report.invalid > 0 do
          Mix.shell().error("\n⚠️  Fixture validation failed")
          exit({:shutdown, 1})
        else
          Mix.shell().info("\n✓ All fixtures valid")
        end

      {:error, reason} ->
        Mix.shell().error("Validation failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
