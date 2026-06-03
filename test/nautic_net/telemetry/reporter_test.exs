defmodule NauticNet.Telemetry.ReporterTest do
  use ExUnit.Case

  import Telemetry.Metrics

  describe "the :asap? option" do
    test "reports metrics as soon as they are emitted" do
      start_reporter([last_value("some.metric.value", reporter_options: [asap?: true])])

      telemetry_execute_value(999)

      assert_receive {:report, [:some, :metric, :value], 999}
    end
  end

  describe "the :every_ms option" do
    test "reports metrics at a timed interval" do
      start_reporter([last_value("nautic_net.gps.position", reporter_options: [every_ms: 10])])

      :telemetry.execute([:nautic_net, :gps], %{position: %{lat: 1.23, lon: 4.56}}, %{
        device_id: {123, 456}
      })

      # Should be sent within 10ms
      assert_receive {:report, [:nautic_net, :gps, :position], %{lat: 1.23, lon: 4.56}}, 20

      # Shouldn't repeat until more values come in
      refute_receive {:report, [:nautic_net, :gps, :position], %{lat: 1.23, lon: 4.56}}, 20

      # Check again
      :telemetry.execute([:nautic_net, :gps], %{position: %{lat: 1.23, lon: 4.56}}, %{
        device_id: {123, 456}
      })

      assert_receive {:report, [:nautic_net, :gps, :position], %{lat: 1.23, lon: 4.56}}, 20
    end
  end

  describe "summary metrics" do
    test "calculate measurements at a timed interval" do
      start_reporter([summary("some.metric.value", reporter_options: [every_ms: 10])])

      telemetry_execute_value(1)
      telemetry_execute_value(2)
      telemetry_execute_value(3)
      telemetry_execute_value(4)
      telemetry_execute_value(5)

      assert_receive {:report, [:some, :metric, :value],
                      %{
                        min: 1,
                        max: 5,
                        mean: 3.0,
                        median: 3
                      }}
    end

    test "works with vector data" do
      start_reporter([summary("some.metric.value", reporter_options: [every_ms: 10])])

      telemetry_execute_value(%{magnitude: 1, angle: 0})
      telemetry_execute_value(%{magnitude: 2, angle: :math.pi() / 2})
      telemetry_execute_value(%{magnitude: 3, angle: :math.pi() / 3})
      telemetry_execute_value(%{magnitude: 4, angle: :math.pi() / 4})
      telemetry_execute_value(%{magnitude: 5, angle: :math.pi() / 5})

      assert_receive {:report, [:some, :metric, :value],
                      %{
                        max: %{angle: 0.6283185307179586, magnitude: 5},
                        mean: %{angle: 0.835607735645695, magnitude: 2.7950303022866176},
                        median: %{angle: 1.0471975511965976, magnitude: 3},
                        min: %{angle: 0, magnitude: 1}
                      }}
    end
  end

  describe "set_flush_interval/2" do
    test "changes the output flush rate at runtime" do
      pid = start_reporter([last_value("some.metric.value")], flush_interval_ms: 1_000)

      # At 1 Hz, a value emitted now is not flushed within 50 ms.
      telemetry_execute_value(1)
      refute_receive {:report, [:some, :metric, :value], 1}, 50

      # Speed up to ~100 Hz; the pending value flushes promptly.
      assert :ok = NauticNet.Telemetry.Reporter.set_flush_interval(pid, 10)
      assert_receive {:report, [:some, :metric, :value], 1}, 50
    end
  end

  defp start_reporter(metrics, opts \\ []) do
    test_pid = self()

    base = [
      metrics: metrics,
      # Flush interval metrics quickly so the timed tests are fast.
      flush_interval_ms: 10,
      callback: fn name, _source_addr, value -> send(test_pid, {:report, name, value}) end
    ]

    {:ok, pid} = NauticNet.Telemetry.Reporter.start_link(Keyword.merge(base, opts))
    pid
  end

  defp telemetry_execute_value(value) do
    :telemetry.execute([:some, :metric], %{value: value}, %{device_id: {123, 456}})
  end
end
