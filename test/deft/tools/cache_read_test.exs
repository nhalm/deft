defmodule Deft.Tools.CacheReadTest do
  use ExUnit.Case, async: false

  alias Deft.Tools.CacheRead
  alias Deft.Tool.Context
  alias Deft.Message.Text
  alias Deft.Store

  setup do
    # Create temporary directory for DETS files
    tmp_dir =
      Path.join(System.tmp_dir!(), "cache_read_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Start a cache store instance
    dets_path = Path.join(tmp_dir, "cache.dets")

    {:ok, store_pid} =
      Store.start_link(
        name: {:cache, "session-test", "lead-test"},
        type: :cache,
        dets_path: dets_path
      )

    cache_tid = Store.tid(store_pid)

    context = %Context{
      working_dir: tmp_dir,
      session_id: "session-test",
      emit: fn _msg -> :ok end,
      bash_timeout: 120_000,
      cache_tid: cache_tid
    }

    on_exit(fn ->
      if Process.alive?(store_pid) do
        Store.cleanup(store_pid)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{context: context, cache_tid: cache_tid, store_pid: store_pid}
  end

  describe "behaviour implementation" do
    test "implements Deft.Tool behaviour" do
      assert CacheRead.name() == "cache_read"
      assert is_binary(CacheRead.description())
      assert is_map(CacheRead.parameters())
    end

    test "has required parameter schema" do
      params = CacheRead.parameters()
      assert params["type"] == "object"
      assert params["required"] == ["key"]
      assert Map.has_key?(params["properties"], "key")
      assert Map.has_key?(params["properties"], "lines")
      assert Map.has_key?(params["properties"], "filter")
    end
  end

  describe "reading cached results" do
    test "returns full cached result when no filters provided", %{
      context: context,
      store_pid: store_pid
    } do
      # Write a test entry to cache
      Store.write(store_pid, "test-key-1", "This is cached content", %{tool: :grep})

      args = %{"key" => "test-key-1"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result == "This is cached content"
    end

    test "returns error for non-existent key", %{context: context} do
      args = %{"key" => "nonexistent-key"}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Cache key not found"
    end

    test "returns error when cache_tid is nil", %{context: context} do
      context_no_cache = %{context | cache_tid: nil}
      args = %{"key" => "test-key"}
      assert {:error, error} = CacheRead.execute(args, context_no_cache)
      assert error =~ "Cache not available"
    end

    test "returns error when key parameter is missing", %{context: context} do
      args = %{}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Missing required parameter: key"
    end
  end

  describe "line range filtering" do
    setup %{store_pid: store_pid} do
      # Create multi-line content
      content = """
      Line 1
      Line 2
      Line 3
      Line 4
      Line 5
      Line 6
      Line 7
      Line 8
      Line 9
      Line 10
      """

      Store.write(store_pid, "multiline-key", String.trim(content), %{tool: :read})
      :ok
    end

    test "extracts specific line range", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "3-5"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)

      # Should contain lines 3, 4, 5
      assert result =~ "Line 3"
      assert result =~ "Line 4"
      assert result =~ "Line 5"
      refute result =~ "Line 2"
      refute result =~ "Line 6"
    end

    test "handles single line range", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "7-7"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result == "Line 7"
    end

    test "handles range at start of content", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "1-2"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result =~ "Line 1"
      assert result =~ "Line 2"
      refute result =~ "Line 3"
    end

    test "handles range at end of content", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "9-10"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result =~ "Line 9"
      assert result =~ "Line 10"
    end

    test "returns error for invalid line range format", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "invalid"}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Invalid line range format"
    end

    test "returns error for invalid range (start > end)", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "5-3"}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Invalid line range format"
    end

    test "returns error for zero or negative line numbers", %{context: context} do
      args = %{"key" => "multiline-key", "lines" => "0-5"}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Invalid line range format"
    end
  end

  describe "pattern filtering" do
    setup %{store_pid: store_pid} do
      content = """
      apple banana
      cherry date
      apple elderberry
      fig grape
      banana apple
      """

      Store.write(store_pid, "grep-key", String.trim(content), %{tool: :grep})
      :ok
    end

    test "filters lines matching regex pattern", %{context: context} do
      args = %{"key" => "grep-key", "filter" => "apple"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)

      # Should contain all lines with "apple"
      assert result =~ "apple banana"
      assert result =~ "apple elderberry"
      assert result =~ "banana apple"
      refute result =~ "cherry date"
      refute result =~ "fig grape"
    end

    test "supports regex patterns", %{context: context} do
      args = %{"key" => "grep-key", "filter" => "^apple"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)

      # Should only contain lines starting with "apple"
      assert result =~ "apple banana"
      assert result =~ "apple elderberry"
      refute result =~ "banana apple"
    end

    test "returns message when no matches found", %{context: context} do
      args = %{"key" => "grep-key", "filter" => "nonexistent"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result =~ "(no matches for pattern: nonexistent)"
    end

    test "returns error for invalid regex pattern", %{context: context} do
      args = %{"key" => "grep-key", "filter" => "[invalid"}
      assert {:error, error} = CacheRead.execute(args, context)
      assert error =~ "Invalid regex pattern"
    end
  end

  describe "combined filtering" do
    setup %{store_pid: store_pid} do
      content = """
      1: apple
      2: banana
      3: apple
      4: cherry
      5: apple
      6: date
      7: apple
      8: elderberry
      """

      Store.write(store_pid, "combined-key", String.trim(content), %{tool: :read})
      :ok
    end

    test "applies both line range and pattern filter", %{context: context} do
      # Get lines 2-6, then filter for "apple"
      args = %{"key" => "combined-key", "lines" => "2-6", "filter" => "apple"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)

      # Should contain lines 3 and 5 (both have "apple" and are in range 2-6)
      assert result =~ "3: apple"
      assert result =~ "5: apple"
      refute result =~ "1: apple"
      refute result =~ "7: apple"
      refute result =~ "banana"
      refute result =~ "cherry"
    end
  end

  describe "cache expiration" do
    test "returns expired error when cache_tid is nil", %{context: context} do
      # Simulate cache being cleaned up by setting cache_tid to nil
      context_expired = %{context | cache_tid: nil}
      args = %{"key" => "test-key"}

      assert {:error, error} = CacheRead.execute(args, context_expired)
      assert error =~ "Cache not available"
    end
  end

  describe "data type handling" do
    test "handles string cached values", %{context: context, store_pid: store_pid} do
      Store.write(store_pid, "string-key", "Simple string", %{})
      args = %{"key" => "string-key"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert result == "Simple string"
    end

    test "handles map cached values by converting to string", %{
      context: context,
      store_pid: store_pid
    } do
      Store.write(store_pid, "map-key", %{data: "value", count: 42}, %{})
      args = %{"key" => "map-key"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      # to_string on a map produces inspect-like output
      assert is_binary(result)
    end

    test "handles list cached values by converting to string", %{
      context: context,
      store_pid: store_pid
    } do
      Store.write(store_pid, "list-key", ["item1", "item2", "item3"], %{})
      args = %{"key" => "list-key"}
      assert {:ok, [%Text{text: result}]} = CacheRead.execute(args, context)
      assert is_binary(result)
    end
  end
end
