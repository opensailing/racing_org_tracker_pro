#
# Configuration for testing the app in local development (not on-device).
#
import Config

# Don't start these servers for testing; we will supervise them manually
# in the test cases
config :nautic_net_device, NauticNet.CAN, false
config :nautic_net_device, NauticNet.Discovery, false
config :nautic_net_device, NauticNet.Serial, false

# The application boots an NMEA 2000 VirtualDevice as part of its supervision
# tree. Give it the Fake driver so the tree starts without real CAN hardware.
config :nmea, NMEA.VirtualDevice,
  driver: {NMEA.NMEA2000.Driver.Fake, []},
  class_code: 25,
  function_code: 130,
  manufacture_code: 999,
  manufacture_string: "Dockyard - www.dockyard.com",
  product_code: 888,
  previous_address: 34,
  device_instance: 0,
  data_instance: 0,
  system_instance: 0,
  model_id: "proto-123",
  model_version: "v1.0.0",
  software_version: "v0.0.1",
  serial_number: "12345",
  load_equivelency_number: 0,
  certification_level: :level_a
