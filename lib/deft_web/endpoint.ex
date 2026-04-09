defmodule DeftWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for Deft web UI.

  Serves on localhost with dynamic port selection (tries 4000, then 4001-4099),
  provides LiveView socket at /live, and handles static asset serving.
  """

  use Phoenix.Endpoint, otp_app: :deft

  alias Deft.Project

  @doc """
  Returns endpoint config with a dynamically selected port.

  Tries the configured port (from PORT env or 4000), and if that's in use,
  tries ports 4001-4099. Writes the actual port to the project pidfile.

  Called from Application.start/2 and passed to the endpoint child spec.
  """
  @spec port_config() :: keyword()
  def port_config do
    http_config = Application.get_env(:deft, __MODULE__, []) |> Keyword.get(:http, [])
    initial_port = Keyword.get(http_config, :port, 4000)
    ip = Keyword.get(http_config, :ip, {127, 0, 0, 1})

    case find_available_port(initial_port, ip) do
      {:ok, port} ->
        write_pidfile(port)
        [http: [ip: ip, port: port]]

      {:error, :no_ports_available} ->
        raise """
        Could not find an available port in range 4000-4099.
        Please free up some ports or set the PORT environment variable to a specific port.
        """
    end
  end

  # Try to find an available port, starting with the initial port
  defp find_available_port(initial_port, ip) when initial_port >= 4000 and initial_port < 4100 do
    # Try the initial port first
    case try_port(initial_port, ip) do
      :ok -> {:ok, initial_port}
      :eaddrinuse -> try_ports_in_range(4001, 4099, ip)
    end
  end

  defp find_available_port(initial_port, ip) do
    # If initial_port is outside our range, try it first, then fall back to range
    case try_port(initial_port, ip) do
      :ok -> {:ok, initial_port}
      :eaddrinuse -> try_ports_in_range(4000, 4099, ip)
    end
  end

  # Try ports in the given range
  defp try_ports_in_range(start_port, end_port, ip) do
    Enum.reduce_while(start_port..end_port, {:error, :no_ports_available}, fn port, _acc ->
      case try_port(port, ip) do
        :ok -> {:halt, {:ok, port}}
        :eaddrinuse -> {:cont, {:error, :no_ports_available}}
      end
    end)
  end

  # Try to bind to a port to check if it's available
  defp try_port(port, ip) do
    case :gen_tcp.listen(port, [:binary, ip: ip, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, :eaddrinuse} ->
        :eaddrinuse

      {:error, _other} ->
        :eaddrinuse
    end
  end

  # Write the port to the pidfile
  defp write_pidfile(port) do
    pidfile_path = Project.project_dir() |> Path.join("server.pid")

    # Ensure project directory exists
    _ = Project.ensure_project_dirs()

    # Write port to pidfile
    File.write!(pidfile_path, "#{port}\n")
  end

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_deft_key",
    signing_salt: "deft_session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: {__MODULE__, :check_origin?, []},
      connect_info: [session: @session_options]
    ],
    longpoll: false
  )

  @doc """
  Checks the websocket origin against CHECK_ORIGIN env var.

  Deft is a local tool — returns true (allow all) when CHECK_ORIGIN is unset.
  Set CHECK_ORIGIN to a comma-separated list of allowed origins to restrict access.
  Example: CHECK_ORIGIN="//localhost,//127.0.0.1,//192.168.10.13"
  """
  def check_origin?(%URI{} = uri) do
    case System.get_env("CHECK_ORIGIN") do
      nil -> true
      "false" -> true
      origins -> origin_in_list?(uri, String.split(origins, ",", trim: true))
    end
  end

  defp origin_in_list?(uri, allowed_origins) do
    Enum.any?(allowed_origins, fn allowed ->
      %{scheme: scheme, host: host, port: port} = URI.parse(allowed)

      (is_nil(scheme) or uri.scheme == scheme) and
        (is_nil(port) or uri.port == port) and
        uri.host == host
    end)
  end

  # Serve static files from the "priv/static" directory
  plug(Plug.Static,
    at: "/",
    from: :deft,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket,
      websocket: [check_origin: {__MODULE__, :check_origin?, []}]
    )

    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(DeftWeb.Router)
end
