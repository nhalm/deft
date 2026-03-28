defmodule Deft.Eval.BaselinesTest do
  use ExUnit.Case, async: false

  alias Deft.Eval.Baselines

  @baselines_file "test/eval/baselines.json"
  @backup_file "test/eval/baselines.json.backup"

  setup do
    # Backup existing baselines file if it exists
    if File.exists?(@baselines_file) do
      File.cp!(@baselines_file, @backup_file)
    end

    on_exit(fn ->
      # Restore backup or remove test file
      if File.exists?(@backup_file) do
        File.rename!(@backup_file, @baselines_file)
      else
        File.rm(@baselines_file)
      end
    end)

    :ok
  end

  describe "load/0" do
    test "returns empty map when file doesn't exist" do
      File.rm(@baselines_file)
      assert {:ok, baselines} = Baselines.load()
      assert baselines == %{}
    end

    test "loads baselines from file" do
      # Write a test baselines file
      data = %{
        "observer.extraction" => %{
          "baseline" => 0.88,
          "soft_floor" => 0.78,
          "history" => [
            %{"run_id" => "2026-03-10-abc123", "rate" => 0.85, "n" => 20, "commit" => "abc123"}
          ]
        }
      }

      File.write!(@baselines_file, Jason.encode!(data))

      assert {:ok, baselines} = Baselines.load()
      assert Map.has_key?(baselines, "observer.extraction")

      baseline = baselines["observer.extraction"]
      assert baseline.baseline == 0.88
      assert baseline.soft_floor == 0.78
      assert length(baseline.history) == 1

      [entry] = baseline.history
      assert entry.run_id == "2026-03-10-abc123"
      assert entry.rate == 0.85
      assert entry.n == 20
      assert entry.commit == "abc123"
    end

    test "returns error for invalid JSON" do
      File.write!(@baselines_file, "not valid json")
      assert {:error, {:json_decode_error, _}} = Baselines.load()
    end
  end

  describe "save/1" do
    test "saves baselines to file" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.88,
          soft_floor: 0.78,
          history: [
            %{run_id: "2026-03-10-abc123", rate: 0.85, n: 20, commit: "abc123"}
          ]
        }
      }

      assert :ok = Baselines.save(baselines)
      assert File.exists?(@baselines_file)

      # Verify contents
      {:ok, content} = File.read(@baselines_file)
      {:ok, decoded} = Jason.decode(content)

      assert decoded["observer.extraction"]["baseline"] == 0.88
      assert decoded["observer.extraction"]["soft_floor"] == 0.78
      assert length(decoded["observer.extraction"]["history"]) == 1
    end

    test "creates directory if it doesn't exist" do
      # Remove directory
      File.rm_rf!("test/eval")

      baselines = %{
        "test.category" => %{
          baseline: 0.90,
          soft_floor: 0.80,
          history: []
        }
      }

      assert :ok = Baselines.save(baselines)
      assert File.exists?(@baselines_file)
    end
  end

  describe "update/3" do
    test "creates new baseline for category if it doesn't exist" do
      baselines = %{}

      updated =
        Baselines.update(baselines, "observer.extraction", %{
          rate: 0.88,
          n: 20,
          run_id: "2026-03-10-abc123",
          commit: "abc123"
        })

      assert Map.has_key?(updated, "observer.extraction")
      baseline = updated["observer.extraction"]

      assert baseline.baseline == 0.88
      assert baseline.soft_floor == 0.78
      assert length(baseline.history) == 1

      [entry] = baseline.history
      assert entry.run_id == "2026-03-10-abc123"
      assert entry.rate == 0.88
      assert entry.n == 20
      assert entry.commit == "abc123"
    end

    test "raises baseline when new rate is higher" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.85,
          soft_floor: 0.75,
          history: [
            %{run_id: "2026-03-09-old123", rate: 0.85, n: 20, commit: "old123"}
          ]
        }
      }

      updated =
        Baselines.update(baselines, "observer.extraction", %{
          rate: 0.90,
          n: 20,
          run_id: "2026-03-10-new123",
          commit: "new123"
        })

      baseline = updated["observer.extraction"]

      # Baseline should be raised
      assert baseline.baseline == 0.90
      # Soft floor should be recalculated
      assert baseline.soft_floor == 0.80
      # History should include new entry
      assert length(baseline.history) == 2
      [new_entry | _] = baseline.history
      assert new_entry.run_id == "2026-03-10-new123"
    end

    test "keeps baseline when new rate is lower (baselines only go up)" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.90,
          soft_floor: 0.80,
          history: [
            %{run_id: "2026-03-09-high123", rate: 0.90, n: 20, commit: "high123"}
          ]
        }
      }

      updated =
        Baselines.update(baselines, "observer.extraction", %{
          rate: 0.85,
          n: 20,
          run_id: "2026-03-10-low123",
          commit: "low123"
        })

      baseline = updated["observer.extraction"]

      # Baseline should NOT decrease
      assert baseline.baseline == 0.90
      # Soft floor should remain based on baseline
      assert baseline.soft_floor == 0.80
      # History should still include new entry (for trend tracking)
      assert length(baseline.history) == 2
      [new_entry | _] = baseline.history
      assert new_entry.run_id == "2026-03-10-low123"
      assert new_entry.rate == 0.85
    end

    test "adds entries to history in newest-first order" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.85,
          soft_floor: 0.75,
          history: [
            %{run_id: "2026-03-08-aaa", rate: 0.85, n: 20, commit: "aaa"}
          ]
        }
      }

      updated =
        baselines
        |> Baselines.update("observer.extraction", %{
          rate: 0.87,
          n: 20,
          run_id: "2026-03-09-bbb",
          commit: "bbb"
        })
        |> Baselines.update("observer.extraction", %{
          rate: 0.90,
          n: 20,
          run_id: "2026-03-10-ccc",
          commit: "ccc"
        })

      baseline = updated["observer.extraction"]
      assert length(baseline.history) == 3

      # History should be in newest-first order
      [first, second, third] = baseline.history
      assert first.run_id == "2026-03-10-ccc"
      assert second.run_id == "2026-03-09-bbb"
      assert third.run_id == "2026-03-08-aaa"
    end
  end

  describe "get_baseline/2" do
    test "returns baseline for existing category" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.88,
          soft_floor: 0.78,
          history: []
        }
      }

      baseline = Baselines.get_baseline(baselines, "observer.extraction")
      assert baseline.baseline == 0.88
      assert baseline.soft_floor == 0.78
    end

    test "returns nil for non-existent category" do
      baselines = %{}
      assert Baselines.get_baseline(baselines, "nonexistent.category") == nil
    end
  end

  describe "below_soft_floor?/3" do
    test "returns true when rate is below soft floor" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.88,
          soft_floor: 0.78,
          history: []
        }
      }

      assert Baselines.below_soft_floor?(baselines, "observer.extraction", 0.75) == true
    end

    test "returns false when rate is at or above soft floor" do
      baselines = %{
        "observer.extraction" => %{
          baseline: 0.88,
          soft_floor: 0.78,
          history: []
        }
      }

      assert Baselines.below_soft_floor?(baselines, "observer.extraction", 0.78) == false
      assert Baselines.below_soft_floor?(baselines, "observer.extraction", 0.85) == false
    end

    test "returns false for non-existent category" do
      baselines = %{}
      assert Baselines.below_soft_floor?(baselines, "nonexistent.category", 0.50) == false
    end
  end

  describe "categories/1" do
    test "returns sorted list of all categories" do
      baselines = %{
        "reflector.compression" => %{baseline: 0.80, soft_floor: 0.70, history: []},
        "observer.extraction" => %{baseline: 0.88, soft_floor: 0.78, history: []},
        "actor.continuation" => %{baseline: 0.90, soft_floor: 0.80, history: []}
      }

      categories = Baselines.categories(baselines)

      assert categories == [
               "actor.continuation",
               "observer.extraction",
               "reflector.compression"
             ]
    end

    test "returns empty list when no categories exist" do
      baselines = %{}
      assert Baselines.categories(baselines) == []
    end
  end

  describe "integration: load, update, save" do
    test "full workflow works correctly" do
      # Start with empty baselines
      File.rm(@baselines_file)

      # Load (should be empty)
      {:ok, baselines} = Baselines.load()
      assert baselines == %{}

      # Update with first result
      baselines =
        Baselines.update(baselines, "observer.extraction", %{
          rate: 0.85,
          n: 20,
          run_id: "2026-03-10-abc",
          commit: "abc"
        })

      # Save
      :ok = Baselines.save(baselines)

      # Load again and verify
      {:ok, loaded} = Baselines.load()
      baseline = loaded["observer.extraction"]
      assert baseline.baseline == 0.85
      assert baseline.soft_floor == 0.75

      # Update with higher rate
      updated =
        Baselines.update(loaded, "observer.extraction", %{
          rate: 0.90,
          n: 20,
          run_id: "2026-03-11-def",
          commit: "def"
        })

      :ok = Baselines.save(updated)

      # Load and verify baseline increased
      {:ok, final} = Baselines.load()
      final_baseline = final["observer.extraction"]
      assert final_baseline.baseline == 0.90
      assert final_baseline.soft_floor == 0.80
      assert length(final_baseline.history) == 2
    end
  end
end
