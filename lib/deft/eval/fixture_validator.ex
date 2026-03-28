defmodule Deft.Eval.FixtureValidator do
  @moduledoc """
  Validates that eval fixtures have spec_version fields matching the current spec versions.
  Flags stale fixtures when specs change.
  """

  @spec_mapping %{
    "observer" => "observational-memory",
    "reflector" => "observational-memory",
    "actor" => "harness",
    "foreman" => "orchestration",
    "lead" => "orchestration",
    "spilling" => "filesystem",
    "skills" => "skills",
    "issues" => "issues",
    "e2e" => "evals"
  }

  @doc """
  Validates all fixtures in the given directory.
  Returns {:ok, report} or {:error, reason}.

  Report structure:
  %{
    total: integer(),
    valid: integer(),
    stale: integer(),
    invalid: integer(),
    stale_fixtures: [%{path: String.t(), current_version: String.t(), expected_version: String.t()}],
    invalid_fixtures: [%{path: String.t(), error: String.t()}]
  }
  """
  def validate_fixtures(fixtures_dir \\ "test/eval/fixtures") do
    with {:ok, spec_versions} <- load_spec_versions(),
         {:ok, fixtures} <- scan_fixtures(fixtures_dir) do
      report = validate_all(fixtures, spec_versions, fixtures_dir)
      {:ok, report}
    end
  end

  @doc """
  Loads current spec versions from specs/ directory.
  Returns {:ok, %{spec_name => version}} or {:error, reason}.
  """
  def load_spec_versions do
    specs_dir = "specs"

    spec_versions =
      Map.new(Map.values(@spec_mapping), fn spec_name ->
        version = read_spec_version(specs_dir, spec_name)
        {spec_name, version}
      end)

    {:ok, spec_versions}
  end

  @doc """
  Reads the version from a spec file.
  Returns the version string (e.g., "0.1") or nil if not found.
  """
  def read_spec_version(specs_dir, spec_name) do
    # Check for both direct .md files and subdirectories with README.md
    paths = [
      Path.join(specs_dir, "#{spec_name}.md"),
      Path.join([specs_dir, spec_name, "README.md"])
    ]

    Enum.find_value(paths, &extract_version_from_file/1)
  end

  defp extract_version_from_file(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path) do
      # Match: | Version | 0.1 |
      case Regex.run(~r/\|\s*Version\s*\|\s*([0-9]+\.[0-9]+)\s*\|/, content) do
        [_, version] -> version
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Scans fixtures directory and returns list of fixture file paths.
  """
  def scan_fixtures(fixtures_dir) do
    if File.dir?(fixtures_dir) do
      fixtures =
        Path.join(fixtures_dir, "**/*.json")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, "/."))

      {:ok, fixtures}
    else
      {:error, "Fixtures directory not found: #{fixtures_dir}"}
    end
  end

  @doc """
  Validates all fixtures against expected spec versions.
  """
  def validate_all(fixture_paths, spec_versions, fixtures_dir) do
    results = Enum.map(fixture_paths, &validate_fixture(&1, spec_versions, fixtures_dir))

    %{
      total: length(results),
      valid: count_status(results, :valid),
      stale: count_status(results, :stale),
      invalid: count_status(results, :invalid),
      stale_fixtures: collect_stale_fixtures(results),
      invalid_fixtures: collect_invalid_fixtures(results)
    }
  end

  defp count_status(results, status) do
    Enum.count(results, &(&1.status == status))
  end

  defp collect_stale_fixtures(results) do
    results
    |> Enum.filter(&(&1.status == :stale))
    |> Enum.map(&Map.take(&1, [:path, :current_version, :expected_version, :spec]))
  end

  defp collect_invalid_fixtures(results) do
    results
    |> Enum.filter(&(&1.status == :invalid))
    |> Enum.map(&Map.take(&1, [:path, :error]))
  end

  @doc """
  Validates a single fixture against its expected spec version.
  """
  def validate_fixture(path, spec_versions, fixtures_dir) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, fixture} ->
            validate_fixture_content(fixture, path, spec_versions, fixtures_dir)

          {:error, reason} ->
            %{
              path: path,
              status: :invalid,
              error: "JSON decode error: #{inspect(reason)}"
            }
        end

      {:error, reason} ->
        %{
          path: path,
          status: :invalid,
          error: "File read error: #{inspect(reason)}"
        }
    end
  end

  defp validate_fixture_content(fixture, path, spec_versions, fixtures_dir) do
    relative_path = Path.relative_to(path, fixtures_dir)

    # Extract component from path (e.g., "observer/extraction_test.json" -> "observer")
    component = extract_component(relative_path)

    # Look up the spec this component belongs to
    spec = Map.get(@spec_mapping, component)

    cond do
      is_nil(spec) ->
        %{
          path: relative_path,
          status: :invalid,
          error: "Unknown component: #{component}"
        }

      !Map.has_key?(fixture, "spec_version") ->
        %{
          path: relative_path,
          status: :invalid,
          error: "Missing spec_version field"
        }

      true ->
        current_version = fixture["spec_version"]
        expected_version = Map.get(spec_versions, spec)

        if current_version == expected_version do
          %{
            path: relative_path,
            status: :valid,
            spec: spec,
            version: current_version
          }
        else
          %{
            path: relative_path,
            status: :stale,
            spec: spec,
            current_version: current_version,
            expected_version: expected_version
          }
        end
    end
  end

  defp extract_component(path) do
    # Extract the first directory component from the path
    # e.g., "observer/extraction_test.json" -> "observer"
    # e.g., "holdout/observer/test.json" -> "observer" (skip holdout)
    parts = Path.split(path)

    case parts do
      ["holdout", component | _] -> component
      [component | _] -> component
      _ -> "unknown"
    end
  end

  @doc """
  Formats the validation report for terminal output.
  """
  def format_report(report) do
    lines = [
      "\nFixture Validation Report",
      "========================",
      "",
      "Total fixtures: #{report.total}",
      "Valid: #{report.valid}",
      "Stale: #{report.stale}",
      "Invalid: #{report.invalid}"
    ]

    lines =
      if report.stale > 0 do
        stale_details =
          Enum.map(report.stale_fixtures, fn fixture ->
            "  - #{fixture.path} (spec: #{fixture.spec}): " <>
              "current=#{fixture.current_version}, expected=#{fixture.expected_version}"
          end)

        lines ++ ["", "Stale fixtures:"] ++ stale_details
      else
        lines
      end

    lines =
      if report.invalid > 0 do
        invalid_details =
          Enum.map(report.invalid_fixtures, fn fixture ->
            "  - #{fixture.path}: #{fixture.error}"
          end)

        lines ++ ["", "Invalid fixtures:"] ++ invalid_details
      else
        lines
      end

    Enum.join(lines, "\n")
  end
end
