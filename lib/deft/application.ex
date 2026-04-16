defmodule Deft.Application do
  @moduledoc """
  OTP Application for Deft.

  The application supervisor starts the core services required for Deft to operate.
  """

  use Application

  alias Deft.Config
  alias Deft.Git
  alias DeftWeb.Endpoint

  @impl true
  def start(_type, _args) do
    load_dotenv()

    # Note: ANTHROPIC_API_KEY validation is deferred to LLM-using commands
    # (see Deft.CLI.verify_api_key/0). This allows non-LLM commands
    # (--help, --version, config, issue list) to work without an API key.

    # Resolve issues file path using same logic as Deft.Issues.resolve_file_path/0
    issues_file_path =
      case Git.cmd(["rev-parse", "--git-common-dir"]) do
        {output, 0} ->
          common_dir = String.trim(output)
          expanded_common_dir = Path.expand(common_dir, File.cwd!())
          repo_root = Path.dirname(expanded_common_dir)
          Path.join([repo_root, ".deft", "issues.jsonl"])

        _error ->
          Path.join([File.cwd!(), ".deft", "issues.jsonl"])
      end

    # Base children that always start
    base_children = [
      # Event broadcasting registry (duplicate keys for pub/sub)
      {Registry, keys: :duplicate, name: Deft.Registry},
      # Process naming registry (unique keys for :via tuples)
      {Registry, keys: :unique, name: Deft.ProcessRegistry},
      Deft.Provider.Registry,
      Deft.Skills.Registry,
      Deft.Session.Supervisor,
      # Phoenix PubSub for web UI
      {Phoenix.PubSub, name: Deft.PubSub},
      # Phoenix Endpoint for web UI — pass dynamic port at startup
      {Endpoint, Endpoint.port_config()}
    ]

    # Conditionally add Issues if issues.jsonl exists
    # Can be disabled via config (e.g., in test environment where tests start Issues with specific paths)
    auto_start_issues = Application.get_env(:deft, :auto_start_issues, true)

    children =
      if auto_start_issues and File.exists?(issues_file_path) do
        config = Config.load(%{}, File.cwd!())
        base_children ++ [{Deft.Issues, [compaction_days: config.issues_compaction_days]}]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: Deft.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp load_dotenv do
    case Dotenvy.source([".env"]) do
      {:ok, vars} -> System.put_env(vars)
      {:error, _} -> :ok
    end
  end
end
