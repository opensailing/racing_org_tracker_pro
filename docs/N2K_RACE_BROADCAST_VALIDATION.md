# NMEA 2000 Race-Broadcast On-Hardware Validation

Turn-key checklist for validating the two race-broadcast PGNs this firmware can emit on
the boat's NMEA 2000 bus:

| Broadcast | PGN(s) | Module |
|---|---|---|
| Race-start countdown ("Race Timer") | 130824 Key 117 | `RacingOrg.Tracker.Compute.RaceTimerBroadcaster` |
| Next waypoint (bearing/distance) | 129284 + 129285 | `RacingOrg.Tracker.Compute.WaypointBroadcaster` |

Both broadcast ALWAYS — whenever the device holds an active race assignment — with no
gate. They are PROPRIETARY/best-effort wire formats whose acceptance by a real B&G/Zeus
display is unverified; this run confirms it on the wire + the display. **The on-boat run
is the OWNER's**; this doc makes it turn-key.

> **The actual numbers in this doc are quoted from the real code** (`pgn_encode.ex`,
> the broadcasters, `config/target.exs`) as of this branch. If you change the code, the
> "expected" bytes below change too.

---

## 1. Prerequisites

1. **Deployed backend** running the race-timeline engine (RacingOrg) so a scheduled race
   becomes the device's active assignment. The assignment MUST carry the gun time and
   start window (see [§6 Backend cross-reference](#6-backend-cross-reference)).
2. **This firmware flashed.** Both broadcasters are ALWAYS ON, so a normal burn (`mix
   firmware` / `mix firmware.signed` / upload) is all that's needed — no env vars, no code
   edit. They sit idle until the device holds an active race assignment, then broadcast at
   ~1 Hz.

3. **The device on the boat's N2K bus** alongside a **B&G/Zeus** (or **Triton2**) MFD/
   display.
4. **An N2K sniffer on the same bus** — one of:
   - **canboat**: `candump can0 | candump2analyzer | analyzer -json` (or `analyzer
     -explain` for a one-off), best for byte-level decode.
   - **Actisense** NGT-1 + Actisense Reader / NMEA Reader.
   - **Yacht Devices** YDNU-02 / Web Gauge.

   Identify THIS device on the bus first: it advertises (from `config/target.exs` →
   `:nmea, NMEA.VirtualDevice`) **manufacture_code 999**, class 25, function 130,
   product 888, model `"proto-123"`, manufacturer string `"Dockyard -
   www.dockyard.com"`. Note its **source address** so you can filter its frames. (That
   mfr 999 is itself a validation risk — see [§3 open question D](#open-question-d--device-name--manufacturer-filtering).)

---

## 2. Set up the scenario

1. In the app/web, **create a race scheduled ~10 minutes out** and assign this boat to
   it, so it becomes the device's **active** race assignment.
2. **Confirm the device received the assignment** (gun + sequence + course + next mark).
   Either on the backend/app (assignment delivered + acked) or directly on the device:

   ```elixir
   a = RacingOrg.Tracker.Commands.current_assignment()
   a.race_assignment.official_start_time         # the gun (proto timestamp) — must be present
   a.race_assignment.sampling_rules.start_window_seconds  # the start sequence length
   a.active_mark_code                            # the next mark to steer to
   length(a.race_assignment.course_marks)        # course present
   ```

   If `official_start_time` is `nil`, the race timer is silent BY DESIGN — fix the
   backend assignment before going further (see §6).

---

## 3. Validate the Race Timer (PGN 130824 Key 117)

### Steps

1. With the race active and now WITHIN the start sequence (or any time the gun is in the
   future), **confirm a ~1 Hz PGN 130824 fast-packet FROM this device's source address**
   on the sniffer.
2. **Decode + check the exact bytes.** For a 5:00 (300 000 ms) countdown the full
   payload is:

   ```
   7D 99 75 40 E0 93 04 00
   └─┬─┘ └─┬─┘ └────┬────┘
     │     │        └─ value = uint32 LE = 0x00049 3E0 = 300000 ms  (≈ gun − now)
     │     └────────── descriptor: 75 40 → Key 117 (0x075), Length 4
     └──────────────── manufacturer header (LE u16 = 0x997D):
                          mfr 381 (B&G) | reserved bits = 0b11 | industry 4 (Marine)
   ```

   - **Manufacturer header `7D 99`** = `manufacturer_word(381)`: bits[0..10]=381,
     bits[11..12]=`0b11` (reserved, currently SET), bits[13..15]=4 (Marine).
   - **Descriptor `75 40`** = Key 117 (low byte `0x75`, high nibble of key 0) +
     `Length<<4` = `4<<4` = `0x40`.
   - **Value** = `uint32 LE` milliseconds, `gun − now`, decreasing ~1000/s.

   (Source of truth: `PgnEncode.race_timer/1` and the doc-comment example.)
3. **Confirm the B&G display shows the race timer counting down** on its start-line / race
   screen, matching the device's own countdown second-for-second.

### Open questions to settle on hardware

Each has *what to look for* and *where to adjust in code*.

#### Open question A — manufacturer-header reserved bits
The header is currently `7D 99` with the 2 reserved bits SET (`0b11`). Some displays
expect them CLEAR (`0b00` → header would be `7D 19`).
- **Look for:** does the B&G accept/attribute the frame and render the timer? If the
  sniffer shows the frame but the display ignores it, suspect the header.
- **Adjust:** `PgnEncode.manufacturer_word/1` — the `||| 0x3 <<< 11` term (change `0x3`
  to `0x0` to clear the reserved bits). One spot; affects all 130824 keys.

#### Open question B — sign / wrap THROUGH the gun
Before the gun the value counts DOWN. AT/AFTER the gun the current code sends the
**elapsed magnitude** (counts UP from 0), via `through_gun_ms/1`.
- **Look for:** at/after the gun, what does the display want — elapsed magnitude
  (count-up), a value that keeps decreasing through zero / wraps unsigned, or a separate
  "started" flag/key? Watch the display the moment the gun fires.
- **Adjust:** `PgnEncode.through_gun_ms/1` — the SINGLE isolated spot. It currently does
  `remaining >= 0 → remaining; else → -remaining`. Retune post-gun behavior here without
  touching the wire format or the broadcaster. (If a companion "started" key is needed,
  add it in `PgnEncode.race_timer/1` via `serialize_with_entry/3`.)

#### Open question C — companion start-line keys
The device sends ONLY Key 117. A B&G start screen may need sibling 130824 keys to render
the full start view — e.g. Distance to Start Line (Key 152), Line Bearing (272), Line
Bias (273).
- **Look for:** does the timer render ALONE, or does the start screen stay blank/partial
  until the sibling keys are present?
- **Adjust:** `PgnEncode.race_timer/1` composes the header + one entry via
  `serialize_with_entry/3`; add more `serialize_with_entry`-style entries (one per key)
  to the same fast-packet payload, and feed their values from the broadcaster
  (`RaceTimerBroadcaster.do_tick/1`). The start-line geometry would come from the
  assignment's course marks (start pin + boat end).

#### Open question D — device NAME / manufacturer filtering
The `VirtualDevice` advertises **mfr 999** (NOT 381/B&G). A display may FILTER the Race
Timer by the TRANSMITTER's NMEA NAME/manufacturer (i.e. only honor it from a B&G-NAMEd
source), even though the PGN payload itself claims mfr 381.
- **Look for:** the sniffer shows a correct 130824 frame but the B&G ignores it →
  suspect NAME filtering.
- **Adjust:** the VirtualDevice NAME in `config/target.exs` (`:nmea, NMEA.VirtualDevice`
  → `manufacture_code` / `class_code` / `function_code` / `product_code` / `model_id`).
  Advertising a B&G-compatible NAME (mfr 381) is the remediation. (Note: changing the
  advertised NAME affects how the WHOLE device appears on the bus, not just this PGN — do
  it deliberately.)

---

## 4. Validate the next waypoint (PGN 129284 + 129285)

### Steps

1. With the race active, an `active_mark_code` set, that mark carrying a position, AND the
   device holding a recent GPS fix, **confirm ~1 Hz PGN 129284 (+ 129285) FROM this
   device** on the sniffer. (No GPS fix → silent by design.)
2. **Decode 129284 "Navigation Data"** (34-byte fast-packet, priority 3) and check:
   - **Distance to destination** — `uint32 LE` at 0.01 m (metres × 100).
   - **Bearing, position → destination** — `uint16 LE` at 1e-4 rad (the live steer-to
     bearing); the field at byte offset after the ETA sentinels. This is the value the
     data box shows as BTW.
   - **Destination lat/lon** — two `int32 LE` at 1e-7 deg. Should equal the next mark's
     coordinates.
   - **Destination WP number** — `uint32 LE`, the mark's 1-based index in the
     sequence-sorted course.
   - ETA Time/Date fields are the unknown sentinels (`FFFFFFFF` / `FFFF`) — the device
     computes no ETA, expected.

   (Source: `PgnEncode.navigation_data_129284/1`.)
3. **Decode 129285 "Route/WP Information"** (fast-packet, priority 6): a one-waypoint
   route — Start RPS# 1, nItems 1, then WP ID = (129284's Destination WP Number), WP Name
   = the mark code (STRING_LAU, ASCII), WP lat/lon (int32 1e-7). The WP ID is what ties
   the label to 129284. (Source: `PgnEncode.route_wp_129285/1`.)
4. **Confirm the B&G data box shows BTW/DTW** (bearing-to-waypoint / distance-to-waypoint)
   to the next mark, matching the decoded numbers and updating as the boat moves.

### Open question — does the plotter ADOPT the active waypoint?

Does the **Zeus ADOPT the externally-sourced waypoint as its active chart waypoint** (the
**magenta steer line** on the chart), or does it only render the data-box numbers?

- **Research finding:** Navico/Zeus often will **NOT** adopt an externally-sourced active
  waypoint onto the chart (it treats its own internal nav as authoritative). The
  documented workaround for plotters that won't adopt is feeding **NMEA-0183 RMB/APB/BWC**
  into the plotter's 0183 input — but **this device has NO NMEA-0183 OUTPUT path** (its
  only serial port is the LTE-modem GPS *input*), so that fallback is **not buildable
  here.**
- **Reliable target:** the **129284 data-box numbers** (BTW/DTW). Treat magenta-line
  adoption as a *nice-to-have*, not a pass criterion. Record whatever the Zeus does.

---

## 5. Results table

Fill in per item. "Adjustment landed in" lists the exact code site for any change made.

| # | Item | Expected | Observed | Pass/Fail | Adjustment made | Adjustment landed in (file · function) |
|---|------|----------|----------|-----------|-----------------|-----------------------------------------|
| 1 | 130824 present ~1 Hz from this device | 1 frame/s, our source addr | | | | `RaceTimerBroadcaster` (always on; needs an active race assignment) |
| 2 | 130824 header bytes | `7D 99` | | | | `pgn_encode.ex` · `manufacturer_word/1` |
| 3 | 130824 descriptor | `75 40` (Key 117, Len 4) | | | | `pgn_encode.ex` · `race_timer/1` |
| 4 | 130824 value = gun−now (ms) | uint32 LE, ↓ ~1000/s | | | | `pgn_encode.ex` · `race_timer/1` |
| 5 | B&G shows countdown | ticks with device | | | | (display-side / NAME — see #9) |
| 6 | Reserved-bit acceptance (Q-A) | accepted at `0b11` | | | | `pgn_encode.ex` · `manufacturer_word/1` |
| 7 | Through-gun representation (Q-B) | elapsed magnitude | | | | `pgn_encode.ex` · `through_gun_ms/1` |
| 8 | Companion start keys needed? (Q-C) | timer renders alone | | | | `pgn_encode.ex` · `race_timer/1` (+ `serialize_with_entry/3`) |
| 9 | NAME/mfr filtering? (Q-D) | not filtered (mfr 999 ok) | | | | `config/target.exs` · `:nmea, NMEA.VirtualDevice` |
| 10 | 129284 present ~1 Hz | 1 frame/s w/ GPS fix | | | | `WaypointBroadcaster` (always on; needs active mark + GPS fix) |
| 11 | 129284 distance/bearing/dest | matches next mark | | | | `pgn_encode.ex` · `navigation_data_129284/1` |
| 12 | 129285 WP name/ID | mark code, WP# matches | | | | `pgn_encode.ex` · `route_wp_129285/1` |
| 13 | B&G data box BTW/DTW | shows + updates | | | | (display-side) |
| 14 | Zeus adopts active waypoint? | nice-to-have, likely NO | | | | (no 0183 out; data-box is the target) |

**Where each adjustment lands (quick map):**
- Through-gun representation → `lib/racing_org/tracker/compute/pgn_encode.ex` · `through_gun_ms/1`
- Manufacturer header / reserved bits → `lib/racing_org/tracker/compute/pgn_encode.ex` · `manufacturer_word/1`
- Companion 130824 keys → `lib/racing_org/tracker/compute/pgn_encode.ex` · `race_timer/1` (+ `serialize_with_entry/3`), fed from `RaceTimerBroadcaster`
- Device NAME / manufacturer → `config/target.exs` (`:nmea, NMEA.VirtualDevice`)

---

## 6. Backend cross-reference

So the gun actually reaches the device: the race assignment delivered to this device must
carry **`official_start_time`** (the gun) and **`sampling_rules.start_window_seconds`**
(the start-sequence length), which the backend now does.

- `RaceTimerBroadcaster` reads `assignment.race_assignment.official_start_time` for the
  gun (`nil` → silent) and `sampling_rules.start_window_seconds` for the
  `in_start_sequence?/2` window (falling back to 300 s).
- `WaypointBroadcaster` reads `active_mark_code` + the matching `course_marks` entry's
  position for the destination.

If the timer is silent, check the assignment on-device (§2 step 2) BEFORE suspecting the
encoder.

---

## 7. Quick isolated broadcast test (no full race)

To sniff the ENCODING in isolation, drive a broadcaster directly from `iex` with an
injected assignment + clock and the REAL transmit path (the on-device VirtualDevice). The
broadcasters expose every side effect as a `start_link/1` opt (this is the same seam the
host tests use), so you don't need a backend round-trip.

### A. Sniff the encoding with ZERO device state (pure host, prints the bytes)

Run on a host `iex -S mix` (no CAN bus needed) — captures the frame instead of sending it:

```elixir
alias RacingOrg.Tracker.Compute.{RaceTimerBroadcaster, PgnEncode}
alias RacingOrg.Tracker.Commands.Assignment
alias RacingOrg.Protobuf.{RaceAssignment, SamplingRules}

# Fastest path — just the encoder, no GenServer:
gun = ~U[2030-01-01 12:05:00Z]
now = ~U[2030-01-01 12:00:00Z]   # 5:00 before the gun
PgnEncode.race_timer_from(DateTime.to_unix(gun, :millisecond), DateTime.to_unix(now, :millisecond))
#=> <<0x7D, 0x99, 0x75, 0x40, 0xE0, 0x93, 0x04, 0x00>>   (300000 ms)

# Or drive the whole broadcaster with injected seams, capturing frames to this process:
me = self()
race = struct(RaceAssignment,
  official_start_time: RacingOrg.Protobuf.to_proto_timestamp(gun),
  sampling_rules: struct(SamplingRules, start_window_seconds: 300))
assignment = %Assignment{assignment_id: "t", version: 1, command_id: "c", race_assignment: race}

{:ok, _} = RaceTimerBroadcaster.start_link(
  name: nil,
  enabled: true,
  tick_ms: 0,                                  # manual ticks only
  commands: {__MODULE__, spawn_agent(assignment)}, # or a stub returning `assignment`
  now_fn: fn -> now end,
  transmit_fn: fn prio, pgn, payload -> send(me, {:frame, prio, pgn, payload}); :ok end
)
```

(For `commands`, pass anything answering `current_assignment/0|1` returning the
`%Assignment{}` — e.g. the `StubCommands` Agent in
`test/racing_org/tracker/compute/race_timer_broadcaster_test.exs`.)

### B. Inject into the REAL transmit path on the DEVICE (frame hits the bus)

On the device `iex` (validation firmware), start an EXTRA broadcaster instance whose
`transmit_fn` is the real default (broadcasts via `RacingOrg.Tracker.virtual_device()`), with an
injected gun/clock so you don't have to wait for a scheduled race — the sniffer then sees
real 130824 frames on the wire:

```elixir
defmodule TmpCmd do
  def current_assignment, do: Process.get(:tmp_assignment)
end

gun = DateTime.add(DateTime.utc_now(), 300, :second)   # 5:00 from now
race = struct(RacingOrg.Protobuf.RaceAssignment,
  official_start_time: RacingOrg.Protobuf.to_proto_timestamp(gun),
  sampling_rules: struct(RacingOrg.Protobuf.SamplingRules, start_window_seconds: 300))
Process.put(:tmp_assignment,
  %RacingOrg.Tracker.Commands.Assignment{assignment_id: "t", version: 1, command_id: "c", race_assignment: race})

# tick_ms default → ~1 Hz; default transmit fn → real VirtualDevice broadcast.
{:ok, _} = RacingOrg.Tracker.Compute.RaceTimerBroadcaster.start_link(name: nil, enabled: true, commands: TmpCmd)
```

For the waypoint broadcaster, additionally inject `position_fn: fn -> {lat, lon} end` (own
position) and an assignment with `active_mark_code` + a positioned `course_marks` entry;
its `transmit_fn` defaults to the same real VirtualDevice path.

> Use a `name: nil` instance so you don't clash with the supervised one. Stop it with
> `GenServer.stop(pid)` when done.
