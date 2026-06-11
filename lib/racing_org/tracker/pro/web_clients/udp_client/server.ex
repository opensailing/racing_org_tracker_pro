defmodule RacingOrg.Tracker.Pro.WebClients.UDPClient.Server do
  @moduledoc """
  Sends DataSet protobuf packets to the RacingOrg app over a
  device-initiated UDP socket, and receives RacingOrg command replies on that
  same socket, forwarding them to `RacingOrg.Tracker.Pro.Commands`.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def send(binary) do
    GenServer.cast(__MODULE__, {:send, binary})
  end

  @impl true
  def init(opts) do
    hostname = opts[:hostname] || raise "the :hostname option is required"
    port = opts[:port] || raise "the :port option is required"
    commands = opts[:commands] || RacingOrg.Tracker.Pro.Commands

    # Port 0 binds to a random available port specified by the OS. The socket is
    # left in active mode so RacingOrg can reply with commands on the same source
    # address/port. The `:inet` option forces IPv4, because Fly does not support
    # UDP over IPv6 yet.
    {:ok, socket} = :gen_udp.open(0, [:inet, :binary, active: true])

    {:ok,
     %{
       hostname: hostname,
       port: port,
       socket: socket,
       commands: commands
     }}
  end

  @impl true
  def handle_cast({:send, binary}, %{socket: socket, hostname: hostname, port: port} = state) do
    case :gen_udp.send(socket, String.to_charlist(hostname), port, binary) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Error sending UDP packet: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # RacingOrg reply on the device-initiated socket.
  @impl true
  def handle_info({:udp, _socket, _ip, _port, packet}, %{commands: commands} = state) do
    GenServer.cast(commands, {:packet, packet})
    {:noreply, state}
  end

  def handle_info({:udp_passive, _socket}, state), do: {:noreply, state}
end
