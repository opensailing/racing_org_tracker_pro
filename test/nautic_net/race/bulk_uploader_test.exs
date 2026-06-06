defmodule NauticNet.Race.BulkUploaderTest do
  @moduledoc """
  Device-side signed HTTPS BULK uploader.

  Drives a real on-disk `NauticNet.Race.Recording` through the uploader against a
  MOCKED Tesla transport that emulates the Phase 6 server contract
  (`SailRouteWeb.BulkUploadController` + reconciliation oracle):

    * the manifest is submitted as a base64 `manifest_protobuf` blob (+ the JSON
      routing envelope), and DECODES back to the device's chunk set
      (`NauticNet.Protobuf.RaceManifest`);
    * each chunk upload carries the raw bytes base64 under `data` with the declared
      `chunk_index`/`chunk_key`/`checksum`/`byte_count`, and the bytes reassemble
      the original recording;
    * the server's `missing_chunk_indexes` drives WHICH chunks are uploaded
      (resumable): a "missing [c1,c3]" response uploads exactly those, then a
      re-submit returns "complete";
    * a second run with the server already complete uploads NOTHING (idempotent);
    * a chunk POST failure is retried/continued, not fatal.

  Every request is signed (verified here against the device public key over the
  server's canonical assertion).
  """
  use ExUnit.Case, async: false

  alias NauticNet.Protobuf.DataSet
  alias NauticNet.Protobuf.RaceManifest
  alias NauticNet.Race.BulkUploader
  alias NauticNet.Race.Recording
  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.Primitives

  @recording_id "2026-06-03-1"
  @session_id "session-abc"

  setup do
    base = Path.join(System.tmp_dir!(), "nn_bulk_#{System.unique_integer([:positive])}")
    key_base = Path.join(base, "keys")
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: key_base)

    # A recording with a tiny chunk threshold so we get several sealed chunks.
    recording =
      base
      |> Recording.open(%{
        recording_id: @recording_id,
        device_id: "dev-1",
        assignment_id: "asg-1",
        assignment_version: 3,
        course_hash: "ch",
        route_hash: "rh",
        chunk_max_bytes: 1
      })

    {recording, _manifest} =
      Enum.reduce(1..4, recording, fn i, rec ->
        Recording.append(rec, DataSet.encode(DataSet.new(boat_identifier: "b", counter: i)))
      end)
      |> Recording.finalize(device_status: "complete")

    %{base: base, identity: identity, recording: recording}
  end

  # --- helpers: parse + verify a signed request the uploader produced -------

  defp server_canonical(method, path, body, ts, fp) do
    Enum.join(
      [
        "sailroute-bulk-v1",
        String.upcase(method),
        path,
        Base.encode16(:crypto.hash(:sha256, body), case: :lower),
        to_string(ts),
        fp
      ],
      "\n"
    )
  end

  # Assert the request is correctly signed by `identity` (the heart of the auth
  # contract), and return the decoded JSON body + the request path.
  defp verify_and_decode(%Tesla.Env{} = env, identity) do
    headers = Map.new(env.headers)
    fp = headers["x-sailroute-device-fingerprint"]
    ts = String.to_integer(headers["x-sailroute-timestamp"])
    {:ok, sig} = Base.decode64(headers["x-sailroute-signature"])

    assert fp == identity.fingerprint
    path = URI.parse(env.url).path
    message = server_canonical("POST", path, env.body, ts, identity.fingerprint)
    assert Primitives.ed25519_verify(identity.public_key, message, sig)

    {path, Jason.decode!(env.body)}
  end

  # A stateful mock "server": tracks which chunk indexes have been uploaded
  # (verified) and answers manifest submits with the live missing set, derived ONLY
  # from verified uploads (mirrors the server oracle). State lives in an Agent.
  defp start_mock_server(identity, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          verified: MapSet.new(),
          chunk_count: nil,
          manifest_submits: 0,
          chunk_posts: [],
          fail_first_chunk: Keyword.get(opts, :fail_first_chunk, false),
          failed_once: MapSet.new()
        }
      end)

    adapter = fn %Tesla.Env{} = env ->
      {path, body} = verify_and_decode(env, identity)

      cond do
        String.ends_with?(path, "/race_manifests") ->
          handle_manifest(agent, body)

        String.contains?(path, "/chunks") ->
          handle_chunk(agent, body)

        true ->
          {:ok, %Tesla.Env{env | status: 404, body: %{}}}
      end
    end

    {agent, adapter}
  end

  defp handle_manifest(agent, body) do
    # Decode the protobuf manifest the device sent (round-trips the device build).
    blob = Base.decode64!(body["manifest_protobuf"])
    manifest = RaceManifest.decode(blob)
    chunk_count = length(manifest.chunks)

    Agent.update(agent, fn s ->
      %{s | chunk_count: chunk_count, manifest_submits: s.manifest_submits + 1}
    end)

    verified = Agent.get(agent, & &1.verified)
    expected = MapSet.new(0..(chunk_count - 1))
    missing = expected |> MapSet.difference(verified) |> Enum.sort()
    status = if missing == [], do: "complete", else: "incomplete"

    {:ok,
     %Tesla.Env{
       status: 200,
       body: %{
         "verification_status" => status,
         "missing_chunk_indexes" => missing,
         "corrupt_chunk_indexes" => []
       }
     }}
  end

  defp handle_chunk(agent, body) do
    index = body["chunk_index"]
    bytes = Base.decode64!(body["data"])

    # The server recomputes the hash over the received bytes (the oracle).
    server_checksum = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    declared_ok = body["checksum"] == server_checksum and body["byte_count"] == byte_size(bytes)

    state = Agent.get(agent, & &1)

    inject_failure? = state.fail_first_chunk and not MapSet.member?(state.failed_once, index)

    if inject_failure? do
      Agent.update(agent, fn s -> %{s | failed_once: MapSet.put(s.failed_once, index)} end)
      {:error, :econnrefused}
    else
      Agent.update(agent, fn s ->
        verified = if declared_ok, do: MapSet.put(s.verified, index), else: s.verified
        %{s | verified: verified, chunk_posts: [index | s.chunk_posts]}
      end)

      {:ok,
       %Tesla.Env{
         status: 200,
         body: %{
           "verification" => if(declared_ok, do: "verified", else: "corrupt"),
           "server_checksum" => server_checksum,
           "server_byte_count" => byte_size(bytes)
         }
       }}
    end
  end

  defp upload_opts(ctx, agent_adapter, extra \\ []) do
    {_agent, adapter} = agent_adapter

    Keyword.merge(
      [
        base_dir: ctx.base,
        recording_id: @recording_id,
        race_session_id: @session_id,
        identity: ctx.identity,
        adapter: adapter,
        base_url: "http://localhost:4000",
        sleep_fn: fn _ -> :ok end
      ],
      extra
    )
  end

  # --- tests ---------------------------------------------------------------

  test "produced a multi-chunk recording (chunking sanity)", %{recording: recording} do
    assert length(recording.sealed_chunks) >= 2
  end

  test "the manifest blob decodes to the device's chunk set (round-trip)", ctx do
    {agent, adapter} = start_mock_server(ctx.identity)

    BulkUploader.upload(upload_opts(ctx, {agent, adapter}))

    # The mock decoded the protobuf and learned the chunk_count from the chunks[].
    chunk_count = Agent.get(agent, & &1.chunk_count)
    assert chunk_count == length(ctx.recording.sealed_chunks)
  end

  test "uploaded chunk bytes reassemble the original recording", ctx do
    # Capture each uploaded chunk's bytes keyed by index.
    {:ok, store} = Agent.start_link(fn -> %{} end)

    adapter = fn %Tesla.Env{} = env ->
      {path, body} = verify_and_decode(env, ctx.identity)

      cond do
        String.contains?(path, "/chunks") ->
          bytes = Base.decode64!(body["data"])
          Agent.update(store, &Map.put(&1, body["chunk_index"], bytes))

          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{
               "verification" => "verified",
               "server_checksum" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
               "server_byte_count" => byte_size(bytes)
             }
           }}

        true ->
          # Always report incomplete on first submit, then complete.
          submitted = Agent.get(store, &map_size(&1))
          status = if submitted >= length(ctx.recording.sealed_chunks), do: "complete", else: "incomplete"
          expected = MapSet.new(0..(length(ctx.recording.sealed_chunks) - 1))
          uploaded = MapSet.new(Agent.get(store, &Map.keys(&1)))
          missing = expected |> MapSet.difference(uploaded) |> Enum.sort()

          {:ok,
           %Tesla.Env{
             status: 200,
             body: %{"verification_status" => status, "missing_chunk_indexes" => missing}
           }}
      end
    end

    assert {:ok, :complete} = BulkUploader.upload(upload_opts(ctx, {nil, adapter}))

    uploaded = Agent.get(store, & &1)
    # Reassemble in index order and compare to the concatenated on-disk chunk files.
    reassembled =
      uploaded
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> IO.iodata_to_binary()

    original =
      ctx.recording.sealed_chunks
      |> Enum.map(fn d -> File.read!(Path.join(ctx.recording.dir, "chunk-#{d.chunk_id}")) end)
      |> IO.iodata_to_binary()

    assert reassembled == original
  end

  test "submit -> missing subset -> uploads exactly those -> re-submit -> complete", ctx do
    chunk_count = length(ctx.recording.sealed_chunks)
    # Pre-seed: pretend index 0 is already verified server-side, so only 1..n-1 are missing.
    {agent, adapter} = start_mock_server(ctx.identity)
    Agent.update(agent, fn s -> %{s | verified: MapSet.new([0])} end)

    assert {:ok, :complete} = BulkUploader.upload(upload_opts(ctx, {agent, adapter}))

    state = Agent.get(agent, & &1)
    # Exactly the missing indexes (1..n-1) were uploaded; index 0 was NOT re-uploaded.
    uploaded = state.chunk_posts |> Enum.sort() |> Enum.uniq()
    assert uploaded == Enum.to_list(1..(chunk_count - 1))
    refute 0 in uploaded
    # At least two manifest submits: initial + the confirming re-submit.
    assert state.manifest_submits >= 2
  end

  test "a second run with the server already complete uploads nothing (idempotent)", ctx do
    chunk_count = length(ctx.recording.sealed_chunks)
    {agent, adapter} = start_mock_server(ctx.identity)
    # Server already has every chunk verified.
    Agent.update(agent, fn s -> %{s | verified: MapSet.new(0..(chunk_count - 1))} end)

    assert {:ok, :complete} = BulkUploader.upload(upload_opts(ctx, {agent, adapter}))

    state = Agent.get(agent, & &1)
    assert state.chunk_posts == []
    assert state.manifest_submits == 1
  end

  test "a chunk POST failure is retried/continued, not fatal", ctx do
    # Inject a transport failure on the FIRST attempt of each chunk; the bounded
    # retry re-sends and the upload still completes.
    {agent, adapter} = start_mock_server(ctx.identity, fail_first_chunk: true)

    assert {:ok, :complete} =
             BulkUploader.upload(upload_opts(ctx, {agent, adapter}, max_attempts: 3))

    chunk_count = length(ctx.recording.sealed_chunks)
    verified = Agent.get(agent, & &1.verified)
    assert MapSet.equal?(verified, MapSet.new(0..(chunk_count - 1)))
  end

  test "no provisioned identity is a clean no-op", ctx do
    empty_base = Path.join(ctx.base, "no_identity")

    assert {:error, :not_provisioned} =
             BulkUploader.upload(
               base_dir: ctx.base,
               recording_id: @recording_id,
               race_session_id: @session_id,
               base_path: empty_base,
               adapter: fn _ -> flunk("must not hit transport without identity") end
             )
  end

  test "a missing required option is rejected before any request", ctx do
    assert {:error, {:missing, :race_session_id}} =
             BulkUploader.upload(
               base_dir: ctx.base,
               recording_id: @recording_id,
               identity: ctx.identity,
               adapter: fn _ -> flunk("must not hit transport") end
             )
  end

  test "an unknown recording id is reported, not crashed", ctx do
    assert {:error, {:recording_not_found, "nope"}} =
             BulkUploader.upload(
               base_dir: ctx.base,
               recording_id: "nope",
               race_session_id: @session_id,
               identity: ctx.identity,
               adapter: fn _ -> flunk("must not hit transport") end
             )
  end
end
