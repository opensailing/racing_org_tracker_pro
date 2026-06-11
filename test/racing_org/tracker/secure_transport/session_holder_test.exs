defmodule RacingOrg.Tracker.SecureTransport.SessionHolderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.SecureTransport.Session
  alias RacingOrg.Tracker.SecureTransport.SessionHolder

  setup do
    {:ok, pid} = start_supervised({SessionHolder, name: nil})
    %{holder: pid}
  end

  defp session(opts \\ []) do
    Session.new(
      Keyword.merge(
        [
          role: :initiator,
          session_id: <<0::128>>,
          epoch: 0,
          out_key: :binary.copy(<<0xAA>>, 32),
          in_key: :binary.copy(<<0xBB>>, 32)
        ],
        opts
      )
    )
  end

  test "starts idle (no session)", %{holder: h} do
    assert SessionHolder.get_current_session(h) == {:error, :no_session}
    refute SessionHolder.live?(h)
    assert SessionHolder.take_send_counter(h) == {:error, :no_session}
  end

  test "stores and returns the live session", %{holder: h} do
    s = session()
    assert :ok = SessionHolder.put(h, s)
    assert SessionHolder.live?(h)
    assert {:ok, ^s} = SessionHolder.get_current_session(h)
  end

  test "take_send_counter hands out monotonic, never-reused counters", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    counters =
      for _ <- 1..5 do
        {:ok, grant} = SessionHolder.take_send_counter(h)
        grant.counter
      end

    assert counters == [0, 1, 2, 3, 4]
  end

  test "grant carries the sealing key, epoch, session_id, role", %{holder: h} do
    s = session(epoch: 7, session_id: <<1::128>>)
    :ok = SessionHolder.put(h, s)

    {:ok, grant} = SessionHolder.take_send_counter(h)

    assert grant.session_id == s.session_id
    assert grant.out_key == s.out_key
    assert grant.epoch == 7
    assert grant.role == :initiator
    assert grant.counter == 0
  end

  test "get_current_session does NOT advance the counter (only take does)", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    {:ok, s1} = SessionHolder.get_current_session(h)
    {:ok, s2} = SessionHolder.get_current_session(h)
    assert s1.send_counter == s2.send_counter

    {:ok, g} = SessionHolder.take_send_counter(h)
    assert g.counter == 0
    {:ok, after_take} = SessionHolder.get_current_session(h)
    assert after_take.send_counter == 1
  end

  test "take_send_counters/2 reserves a consecutive block", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    {:ok, grants} = SessionHolder.take_send_counters(h, 3)
    assert Enum.map(grants, & &1.counter) == [0, 1, 2]

    {:ok, next} = SessionHolder.take_send_counter(h)
    assert next.counter == 3
  end

  test "concurrent takes never collide (counter uniqueness under contention)", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    n = 200

    counters =
      1..n
      |> Task.async_stream(
        fn _ ->
          {:ok, grant} = SessionHolder.take_send_counter(h)
          grant.counter
        end, max_concurrency: 50, ordered: false)
      |> Enum.map(fn {:ok, c} -> c end)

    assert length(counters) == n
    assert Enum.sort(counters) == Enum.to_list(0..(n - 1))
    assert length(Enum.uniq(counters)) == n
  end

  test "put resets the counter base to the new session's send_counter", %{holder: h} do
    :ok = SessionHolder.put(h, session())
    {:ok, _} = SessionHolder.take_send_counter(h)
    {:ok, _} = SessionHolder.take_send_counter(h)

    # New handshake -> fresh session (counter 0).
    :ok = SessionHolder.put(h, session(session_id: <<9::128>>))
    {:ok, grant} = SessionHolder.take_send_counter(h)
    assert grant.counter == 0
  end

  test "clear drops the session (eviction/disconnect)", %{holder: h} do
    :ok = SessionHolder.put(h, session())
    assert SessionHolder.live?(h)

    assert :ok = SessionHolder.clear(h)
    refute SessionHolder.live?(h)
    assert SessionHolder.get_current_session(h) == {:error, :no_session}
    assert SessionHolder.take_send_counter(h) == {:error, :no_session}

    # clear is idempotent
    assert :ok = SessionHolder.clear(h)
  end
end
