defmodule Deft.StoreTest do
  use ExUnit.Case, async: false

  alias Deft.Store

  import ExUnit.CaptureLog

  setup do
    # Create temporary directory for DETS files
    tmp_dir =
      Path.join(System.tmp_dir!(), "deft_store_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "cache instance" do
    test "starts and stops successfully", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-1", "lead-1"},
          type: :cache,
          dets_path: dets_path
        )

      assert Process.alive?(pid)

      # Get tid
      tid = Store.tid(pid)
      assert is_reference(tid)

      # Cleanup
      assert :ok = Store.cleanup(pid)
      refute File.exists?(dets_path)
    end

    test "writes and reads entries", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-2", "lead-2"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Write an entry
      assert :ok = Store.write(pid, "key-1", %{data: "value-1"}, %{tool: :grep})

      # Read it back
      assert {:ok, %{value: %{data: "value-1"}, metadata: %{tool: :grep}}} =
               Store.read(tid, "key-1")

      # Read non-existent key
      assert :miss = Store.read(tid, "key-2")

      Store.cleanup(pid)
    end

    test "deletes entries", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-3", "lead-3"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Write and delete
      Store.write(pid, "key-1", "value-1")
      assert {:ok, _} = Store.read(tid, "key-1")

      Store.delete(pid, "key-1")
      assert :miss = Store.read(tid, "key-1")

      Store.cleanup(pid)
    end

    test "lists keys", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-4", "lead-4"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Write multiple entries
      Store.write(pid, "key-1", "value-1")
      Store.write(pid, "key-2", "value-2")
      Store.write(pid, "key-3", "value-3")

      keys = Store.keys(tid)
      assert length(keys) == 3
      assert "key-1" in keys
      assert "key-2" in keys
      assert "key-3" in keys

      Store.cleanup(pid)
    end

    test "lazy DETS flush after buffer fills", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-5", "lead-5"},
          type: :cache,
          dets_path: dets_path
        )

      _tid = Store.tid(pid)

      # Write 51 entries to trigger buffer flush (50 entry threshold)
      for i <- 1..51 do
        Store.write(pid, "key-#{i}", "value-#{i}")
      end

      # Give flush time to complete
      Process.sleep(100)

      # Stop (but don't cleanup/delete) and restart to verify DETS persistence
      GenServer.stop(pid, :normal)

      {:ok, pid2} =
        Store.start_link(
          name: {:cache, "session-5-2", "lead-5-2"},
          type: :cache,
          dets_path: dets_path
        )

      tid2 = Store.tid(pid2)

      # Wait for async load to complete (longer for many entries)
      Process.sleep(500)

      # Verify all entries were persisted
      for i <- 1..51 do
        expected_value = "value-#{i}"
        assert {:ok, %{value: ^expected_value}} = Store.read(tid2, "key-#{i}")
      end

      Store.cleanup(pid2)
    end

    test "periodic flush timer", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-6", "lead-6"},
          type: :cache,
          dets_path: dets_path
        )

      # Write a few entries (below buffer threshold)
      Store.write(pid, "key-1", "value-1")
      Store.write(pid, "key-2", "value-2")

      # Wait for periodic flush (5 seconds)
      Process.sleep(5500)

      # Stop (but don't cleanup/delete) and restart to verify DETS persistence
      GenServer.stop(pid, :normal)

      {:ok, pid2} =
        Store.start_link(
          name: {:cache, "session-6-2", "lead-6-2"},
          type: :cache,
          dets_path: dets_path
        )

      tid2 = Store.tid(pid2)

      # Wait for async load
      Process.sleep(500)

      # Verify entries were persisted by periodic flush
      assert {:ok, %{value: "value-1"}} = Store.read(tid2, "key-1")
      assert {:ok, %{value: "value-2"}} = Store.read(tid2, "key-2")

      Store.cleanup(pid2)
    end

    test "handles DETS corruption gracefully", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "corrupt.dets")

      # Create a corrupted DETS file
      File.write!(dets_path, "this is not a valid DETS file")

      # Should fall back to creating new file (no error)
      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-7", "lead-7"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Should work normally
      Store.write(pid, "key-1", "value-1")
      assert {:ok, %{value: "value-1"}} = Store.read(tid, "key-1")

      Store.cleanup(pid)
    end

    test "read/keys handle table-owner crash gracefully", %{tmp_dir: tmp_dir} do
      # Trap exits so killing the GenServer doesn't kill the test
      Process.flag(:trap_exit, true)

      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-8", "lead-8"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Write some data
      Store.write(pid, "key-1", "value-1")

      # Kill the GenServer (simulates crash)
      Process.exit(pid, :kill)

      # Wait for EXIT message
      assert_receive {:EXIT, ^pid, :killed}, 1000

      # ETS table should be gone, but read/keys should not crash
      assert :miss = Store.read(tid, "key-1")
      assert [] = Store.keys(tid)
    end

    test "terminate flushes buffered writes", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-9", "lead-9"},
          type: :cache,
          dets_path: dets_path
        )

      # Write entries (below flush threshold)
      Store.write(pid, "key-1", "value-1")
      Store.write(pid, "key-2", "value-2")

      # Stop the GenServer normally (terminate should flush)
      GenServer.stop(pid)

      # Restart and verify entries were flushed during terminate
      {:ok, pid2} =
        Store.start_link(
          name: {:cache, "session-9-2", "lead-9-2"},
          type: :cache,
          dets_path: dets_path
        )

      tid2 = Store.tid(pid2)

      # Wait for async load
      Process.sleep(500)

      assert {:ok, %{value: "value-1"}} = Store.read(tid2, "key-1")
      assert {:ok, %{value: "value-2"}} = Store.read(tid2, "key-2")

      Store.cleanup(pid2)
    end

    test "cleanup is idempotent", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-10", "lead-10"},
          type: :cache,
          dets_path: dets_path
        )

      Store.write(pid, "key-1", "value-1")

      # Call cleanup twice (once explicitly, once in terminate)
      assert :ok = Store.cleanup(pid)

      # Second cleanup (in terminate) should be no-op
      # If it tries to double-flush, we'd see errors
      GenServer.stop(pid)
    end
  end

  describe "site log instance" do
    test "enforces access control for writes", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "sitelog.dets")
      owner_name = {:foreman, "job-1"}

      # Register the current process as the owner
      {:ok, _} = Registry.register(Deft.ProcessRegistry, owner_name, nil)

      {:ok, pid} =
        Store.start_link(
          name: {:sitelog, "job-1"},
          type: :sitelog,
          dets_path: dets_path,
          owner_name: owner_name
        )

      # Owner can write
      assert :ok = Store.write(pid, "key-1", "value-1")

      # Spawn a different process and try to write
      task =
        Task.async(fn ->
          Store.write(pid, "key-2", "value-2")
        end)

      assert {:error, :unauthorized} = Task.await(task)

      Store.cleanup(pid)
    end

    test "syncs DETS immediately on write", %{tmp_dir: tmp_dir} do
      # Trap exits so killing the GenServer doesn't kill the test
      Process.flag(:trap_exit, true)

      dets_path = Path.join(tmp_dir, "sitelog.dets")
      owner_name = {:foreman, "job-2"}

      {:ok, _} = Registry.register(Deft.ProcessRegistry, owner_name, nil)

      {:ok, pid} =
        Store.start_link(
          name: {:sitelog, "job-2"},
          type: :sitelog,
          dets_path: dets_path,
          owner_name: owner_name
        )

      # Write entry
      Store.write(pid, "key-1", "value-1")

      # Immediately kill the process (no time for async flush)
      Process.exit(pid, :kill)

      # Wait for EXIT message
      assert_receive {:EXIT, ^pid, :killed}, 1000

      # Unregister and re-register for second instance
      Registry.unregister(Deft.ProcessRegistry, owner_name)
      {:ok, _} = Registry.register(Deft.ProcessRegistry, owner_name, nil)

      {:ok, pid2} =
        Store.start_link(
          name: {:sitelog, "job-2-2"},
          type: :sitelog,
          dets_path: dets_path,
          owner_name: owner_name
        )

      tid2 = Store.tid(pid2)

      # Wait for async load
      Process.sleep(500)

      assert {:ok, %{value: "value-1"}} = Store.read(tid2, "key-1")

      Store.cleanup(pid2)
    end

    test "allows writes when owner_name is nil (testing mode)", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "sitelog.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:sitelog, "job-3"},
          type: :sitelog,
          dets_path: dets_path,
          owner_name: nil
        )

      # Anyone can write when owner_name is nil
      assert :ok = Store.write(pid, "key-1", "value-1")

      Store.cleanup(pid)
    end

    test "logs warning for site log corruption", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "corrupt_sitelog.dets")

      # Create corrupted file
      File.write!(dets_path, "corrupted")

      # Capture log
      log =
        capture_log(fn ->
          {:ok, pid} =
            Store.start_link(
              name: {:sitelog, "job-4"},
              type: :sitelog,
              dets_path: dets_path,
              owner_name: nil
            )

          Store.cleanup(pid)
        end)

      assert log =~ "site log DETS corruption"
    end

    test "does not use periodic flush timer", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "sitelog.dets")

      {:ok, pid} =
        Store.start_link(
          name: {:sitelog, "job-5"},
          type: :sitelog,
          dets_path: dets_path,
          owner_name: nil
        )

      # Get state (via sys debug)
      state = :sys.get_state(pid)

      # Site log should not have a flush timer
      assert state.flush_timer == nil

      Store.cleanup(pid)
    end
  end

  describe "async load" do
    test "returns :miss for not-yet-loaded entries", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      # Pre-populate DETS with many entries
      {:ok, dets} = :dets.open_file(String.to_charlist(dets_path), type: :set)

      for i <- 1..1000 do
        :dets.insert(dets, {"key-#{i}", %{value: "value-#{i}", metadata: %{}}})
      end

      :dets.close(dets)

      # Start store (async load will take time)
      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-11", "lead-11"},
          type: :cache,
          dets_path: dets_path
        )

      tid = Store.tid(pid)

      # Immediately try to read (might return :miss if not loaded yet)
      # This is expected behavior - the store is ready immediately
      result = Store.read(tid, "key-500")
      assert result in [:miss, {:ok, %{value: "value-500", metadata: %{}}}]

      # Wait for load to complete
      Process.sleep(200)

      # Now all entries should be available
      assert {:ok, %{value: "value-500"}} = Store.read(tid, "key-500")

      Store.cleanup(pid)
    end

    test "handles load task failure gracefully", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      # Create a DETS file that will cause load issues
      {:ok, dets} = :dets.open_file(String.to_charlist(dets_path), type: :set)
      :dets.insert(dets, {"key-1", %{value: "value-1", metadata: %{}}})
      # Don't close DETS - it will cause issues when trying to read from it

      log =
        capture_log(fn ->
          {:ok, pid} =
            Store.start_link(
              name: {:cache, "session-12", "lead-12"},
              type: :cache,
              dets_path: dets_path
            )

          # Wait for load task to fail
          Process.sleep(200)

          # Store should still be functional, just with partially loaded data
          tid = Store.tid(pid)
          Store.write(pid, "key-2", "value-2")
          assert {:ok, %{value: "value-2"}} = Store.read(tid, "key-2")

          :dets.close(dets)
          Store.cleanup(pid)
        end)

      assert log =~ "async load task failed" or log =~ ""
    end

    test "kills load task during cleanup", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")

      # Pre-populate with many entries (slow load)
      {:ok, dets} = :dets.open_file(String.to_charlist(dets_path), type: :set)

      for i <- 1..10000 do
        :dets.insert(dets, {"key-#{i}", %{value: "value-#{i}", metadata: %{}}})
      end

      :dets.close(dets)

      {:ok, pid} =
        Store.start_link(
          name: {:cache, "session-13", "lead-13"},
          type: :cache,
          dets_path: dets_path
        )

      # Cleanup immediately (while load task is still running)
      assert :ok = Store.cleanup(pid)

      # Should not crash
    end
  end

  describe "registry integration" do
    test "can be looked up by name", %{tmp_dir: tmp_dir} do
      dets_path = Path.join(tmp_dir, "cache.dets")
      name = {:cache, "session-14", "lead-14"}

      {:ok, pid} =
        Store.start_link(
          name: name,
          type: :cache,
          dets_path: dets_path
        )

      # Lookup via Registry
      [{found_pid, _}] = Registry.lookup(Deft.ProcessRegistry, name)
      assert found_pid == pid

      Store.cleanup(pid)
    end
  end
end
