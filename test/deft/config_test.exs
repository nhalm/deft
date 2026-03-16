defmodule Deft.ConfigTest do
  use ExUnit.Case, async: true

  alias Deft.Config

  @temp_dir Path.join(System.tmp_dir!(), "deft_config_test_#{:rand.uniform(1_000_000)}")
  @user_home Path.join(@temp_dir, "user_home")
  @working_dir Path.join(@temp_dir, "working_dir")

  setup do
    # Create temp directories
    File.mkdir_p!(@user_home)
    File.mkdir_p!(@working_dir)
    File.mkdir_p!(Path.join(@user_home, ".deft"))
    File.mkdir_p!(Path.join(@working_dir, ".deft"))

    # Mock System.user_home!/0
    original_user_home = System.get_env("HOME")
    System.put_env("HOME", @user_home)

    on_exit(fn ->
      # Restore original HOME
      if original_user_home do
        System.put_env("HOME", original_user_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directories
      File.rm_rf!(@temp_dir)
    end)

    :ok
  end

  describe "defaults/0" do
    test "returns expected default values" do
      config = Config.defaults()

      assert config.model == "claude-sonnet-4"
      assert config.provider == "anthropic"
      assert config.turn_limit == 25
      assert config.tool_timeout == 120_000
      assert config.bash_timeout == 120_000
      assert config.om.enabled == true
      assert config.om.observer_model == "claude-haiku-4.5"
      assert config.om.reflector_model == "claude-haiku-4.5"
    end
  end

  describe "load/2" do
    test "loads defaults when no config files exist" do
      config = Config.load(%{}, @working_dir, user_home: @user_home)

      assert config.model == "claude-sonnet-4"
      assert config.provider == "anthropic"
      assert config.turn_limit == 25
      assert config.tool_timeout == 120_000
      assert config.bash_timeout == 120_000
      assert config.om_enabled == true
      assert config.om_observer_model == "claude-haiku-4.5"
      assert config.om_reflector_model == "claude-haiku-4.5"
    end

    test "merges user config from ~/.deft/config.yaml" do
      user_config = """
      model: claude-opus-4
      turn_limit: 30
      om:
        observer_model: claude-sonnet-4
      """

      user_config_path = Path.join([@user_home, ".deft", "config.yaml"])
      File.write!(user_config_path, user_config)

      config = Config.load(%{}, @working_dir, user_home: @user_home)

      assert config.model == "claude-opus-4"
      assert config.turn_limit == 30
      assert config.om_observer_model == "claude-sonnet-4"
      # Other defaults remain
      assert config.provider == "anthropic"
      assert config.tool_timeout == 120_000
    end

    test "merges project config from .deft/config.yaml in working_dir" do
      project_config = """
      model: claude-haiku-4
      bash_timeout: 60000
      """

      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])
      File.write!(project_config_path, project_config)

      config = Config.load(%{}, @working_dir, user_home: @user_home)

      assert config.model == "claude-haiku-4"
      assert config.bash_timeout == 60_000
      assert config.provider == "anthropic"
    end

    test "project config overrides user config" do
      user_config = """
      model: claude-opus-4
      turn_limit: 30
      """

      project_config = """
      model: claude-haiku-4
      """

      user_config_path = Path.join([@user_home, ".deft", "config.yaml"])
      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])

      File.write!(user_config_path, user_config)
      File.write!(project_config_path, project_config)

      config = Config.load(%{}, @working_dir, user_home: @user_home)

      # Project config wins for model
      assert config.model == "claude-haiku-4"
      # User config applies for turn_limit
      assert config.turn_limit == 30
    end

    test "CLI flags override all config sources" do
      user_config = """
      model: claude-opus-4
      turn_limit: 30
      """

      project_config = """
      model: claude-haiku-4
      tool_timeout: 60000
      """

      user_config_path = Path.join([@user_home, ".deft", "config.yaml"])
      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])

      File.write!(user_config_path, user_config)
      File.write!(project_config_path, project_config)

      cli_flags = %{
        model: "claude-sonnet-4.5",
        provider: "openai"
      }

      config = Config.load(cli_flags, @working_dir, user_home: @user_home)

      # CLI flags win
      assert config.model == "claude-sonnet-4.5"
      assert config.provider == "openai"
      # Project config applies
      assert config.tool_timeout == 60_000
      # User config applies
      assert config.turn_limit == 30
    end

    test "handles nested om config from CLI flags" do
      cli_flags = %{
        om_enabled: false,
        om_observer_model: "claude-opus-4",
        om_reflector_model: "claude-sonnet-4"
      }

      config = Config.load(cli_flags, @working_dir, user_home: @user_home)

      assert config.om_enabled == false
      assert config.om_observer_model == "claude-opus-4"
      assert config.om_reflector_model == "claude-sonnet-4"
    end

    test "handles nested om config from YAML" do
      project_config = """
      om:
        enabled: false
        observer_model: claude-opus-4
        reflector_model: claude-sonnet-4
      """

      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])
      File.write!(project_config_path, project_config)

      config = Config.load(%{}, @working_dir, user_home: @user_home)

      assert config.om_enabled == false
      assert config.om_observer_model == "claude-opus-4"
      assert config.om_reflector_model == "claude-sonnet-4"
    end

    test "handles malformed YAML gracefully" do
      project_config = """
      model: [this is not valid
      """

      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])
      File.write!(project_config_path, project_config)

      # Should fall back to defaults when YAML parsing fails
      config = Config.load(%{}, @working_dir, user_home: @user_home)
      assert config.model == "claude-sonnet-4"
    end

    test "handles empty YAML file" do
      project_config_path = Path.join([@working_dir, ".deft", "config.yaml"])
      File.write!(project_config_path, "")

      config = Config.load(%{}, @working_dir, user_home: @user_home)
      assert config.model == "claude-sonnet-4"
    end

    test "handles partial om config override" do
      user_config = """
      om:
        observer_model: claude-opus-4
      """

      user_config_path = Path.join([@user_home, ".deft", "config.yaml"])
      File.write!(user_config_path, user_config)

      config = Config.load(%{}, @working_dir, user_home: @user_home)

      # Observer model is overridden
      assert config.om_observer_model == "claude-opus-4"
      # Reflector model remains default
      assert config.om_reflector_model == "claude-haiku-4.5"
      # OM enabled remains default
      assert config.om_enabled == true
    end
  end
end
