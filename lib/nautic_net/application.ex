defmodule NauticNet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: NauticNet.Supervisor]

    children = children(product(), target())

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      {:ok, vd_pid} = start_virtual_device_and_handlers(sup)
      start_discovery(sup, vd_pid)
      maybe_replay_log()
      {:ok, sup}
    end
  end

  defp start_virtual_device_and_handlers(sup) do
    {:ok, emit_telemetry_pid} =
      Supervisor.start_child(sup, {NauticNet.PacketHandler.EmitTelemetry, emit_telemetry_config()})

    {:ok, system_time_pid} = Supervisor.start_child(sup, NauticNet.PacketHandler.SetTimeFromGPS)
    {:ok, pid} = on_start = Supervisor.start_child(sup, {NMEA.NMEA2000.VirtualDevice, virtual_device_config()})

    # Expose the VirtualDevice so NauticNet.Nav.Broadcaster can transmit nav PGNs.
    NauticNet.put_virtual_device(pid)

    # Handlers must be a list of pids which define a
    # def handle_info({:data, data})
    # See NMEA.NMEA2000.VirtualDevice.AddressManager for an example
    handlers = [emit_telemetry_pid, system_time_pid]

    # Register the handlers with the virtual device
    for handler <- handlers do
      NMEA.NMEA2000.VirtualDevice.register_handler(pid, handler)
    end

    on_start
  end

  defp start_discovery(supervisor, virtual_device_pid) do
    {:ok, _discovery_pid} =
      Supervisor.start_child(supervisor, {NauticNet.Discovery, %{virtual_device_pid: virtual_device_pid}})
  end

  # Product: NMEA 2000 standalone, on-board device
  defp children(:logger, target) do
    [
      commands_child(),
      NauticNet.Telemetry,
      {NauticNet.Sampling, name: NauticNet.Sampling},
      archive_child(),
      {NauticNet.Nav.Broadcaster, name: NauticNet.Nav.Broadcaster},
      {NauticNet.Serial, serial_config()},
      # SessionHolder BEFORE the UDP send path + ChannelClient: the UDP path reads
      # the live session from the holder, and the ChannelClient publishes into it.
      NauticNet.SecureTransport.SessionHolder,
      {NauticNet.WebClients.UDPClient, udp_config()},
      {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {NauticNet.DataSetUploader, via: :udp}
    ] ++ secure_transport_children(target)
  end

  # Product: Base station receiver node for nautic_net_tracker_mini
  defp children(:uplink, target) do
    [
      commands_child(),
      NauticNet.SecureTransport.SessionHolder,
      {NauticNet.WebClients.UDPClient, udp_config()},
      {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {NauticNet.DataSetUploader, via: :udp},
      NauticNet.BaseStation
    ] ++ secure_transport_children(target)
  end

  # P9-job-6 secure-transport children, appended after the network/HTTP deps they
  # rely on. The SessionHolder is started inline above (it runs in EVERY environment:
  # the UDP send path + tests read it, and it is idle/cheap with no session). These
  # extra children are gated together by `secure_transport_configured?/1` — a real
  # device target AND the pinned server public key being configured (there is no
  # separate enable flag; the pinned key IS the enable):
  #
  #   * BootProvisioner — one-shot boot self-registration. It generates the device
  #     identity and tokenlessly registers it with the server, which (once an admin
  #     associates it) makes the ChannelClient connectable.
  #   * ChannelClient — outbound WSS command channel. It additionally SELF-GATES in
  #     init (idle unless claimed + identity provisioned + server pinned), so it is
  #     safe even if started before provisioning.
  #   * BulkUploader — thin GenServer giving `upload_async/2` a named server for the
  #     Archive's post-race trigger. Cheap + idle.
  #
  # Each child also self-gates at runtime, so this is belt-and-suspenders. On
  # host/test (`real_target?` false) they never start.
  #
  # Ordering: BootProvisioner (registers) → ChannelClient (connects/handshakes) →
  # BulkUploader, all AFTER SessionHolder.
  defp secure_transport_children(target) do
    if secure_transport_configured?(target) do
      [
        NauticNet.SecureTransport.BootProvisioner,
        NauticNet.SecureTransport.ChannelClient,
        NauticNet.Race.BulkUploader
      ]
    else
      []
    end
  end

  @doc """
  Whether the secure-transport children should start: a real device target AND the
  pinned server public key is configured (`ServerIdentity.configured?`). There is no
  separate enable flag — the pinned key is the single enable. Host/test
  (`real_target?` false) and un-pinned firmware return `false`.
  """
  @spec secure_transport_configured?(atom()) :: boolean()
  def secure_transport_configured?(target) do
    real_target?(target) and NauticNet.SecureTransport.ServerIdentity.configured?()
  end

  defp real_target?(:host), do: false
  defp real_target?(:""), do: false
  defp real_target?(nil), do: false
  defp real_target?(_target), do: true

  # Receives, validates, and de-duplicates SailRoute server commands arriving on
  # the device-initiated UDP socket.
  defp commands_child do
    {NauticNet.Commands,
     name: NauticNet.Commands,
     device_id: NauticNet.boat_identifier(),
     store_dir: Application.get_env(:nautic_net_device, :assignment_directory)}
  end

  # Durable local race archiving + reconciliation with SailRoute.
  defp archive_child do
    {NauticNet.Race.Archive,
     name: NauticNet.Race.Archive,
     base_dir: Application.get_env(:nautic_net_device, :race_archive_directory),
     sampling: NauticNet.Sampling,
     device_id: NauticNet.boat_identifier()}
  end

  defp product do
    case Application.get_env(:nautic_net_device, :product) do
      "logger" ->
        :logger

      "uplink" ->
        :uplink

      unexpected ->
        raise """
        unexpected PRODUCT #{inspect(unexpected)}; must be one of:

             - "logger" for NMEA2000 device
             - "uplink" for mini tracker base station uplink node

        """
    end
  end

  defp target do
    Application.get_env(:nautic_net_device, :target)
  end

  # Get the filtering configuration / settings for NMEA data being
  # set to the cloud.
  # FUTURETODO: Load the current fitters from disk
  defp emit_telemetry_config do
    Application.get_env(:nautic_net_device, :data_filtering)
  end

  defp virtual_device_config do
    Application.get_env(:nmea, NMEA.VirtualDevice, [])
    |> Kernel.++(virtual_device_save_fns(target()))
    |> Enum.into(%{})
  end

  # Functions cannot be defined in target.exs so they kept here and to be merged with the previously
  # defined configs
  defp virtual_device_save_fns(:nautic_net_rpi3) do
    [
      save_fn: fn key, value -> File.write("/root/#{key}.setting", :erlang.term_to_binary(value)) end,
      retrieve_fn: fn key ->
        "/root/#{key}.setting"
        |> File.read()
        |> case do
          {:ok, ""} -> nil
          {:ok, setting} -> :erlang.binary_to_term(setting)
          {:error, _reason} -> nil
        end
      end
    ]
  end

  defp virtual_device_save_fns(_) do
    [
      save_fn: fn _key, _value -> :ok end,
      retrieve_fn: fn _key -> nil end
    ]
  end

  defp serial_config do
    Application.get_env(:nautic_net_device, NauticNet.Serial, [])
  end

  defp udp_config do
    endpoint = Application.get_env(:nautic_net_device, :udp_endpoint, "localhost:4001")
    [hostname, port] = String.split(endpoint, ":")

    [hostname: hostname, port: String.to_integer(port)]
  end

  def maybe_replay_log do
    if filename = Application.get_env(:nautic_net_device, :replay_log) do
      NauticNet.DeviceCLI.replay_log(filename, realtime?: true)
    end
  end
end
