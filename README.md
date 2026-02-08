<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# Feetech

[![CI](https://github.com/beam-bots/feetech/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/feetech/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/feetech.svg)](https://hex.pm/packages/feetech)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/feetech)](https://api.reuse.software/info/github.com/beam-bots/feetech)

Elixir driver for Feetech TTL-based serial bus servos (STS/SCS series).

## Features

- Full protocol support for STS3215 and compatible servos
- Position, velocity, and step operating modes
- Synchronised multi-servo control via sync_read/sync_write
- Buffered writes with action trigger for coordinated movement
- Converted (radians) and raw (steps) APIs
- Mix tasks for servo configuration and debugging

## Installation

Add `feetech` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:feetech, "~> 0.2.2"}
  ]
end
```

## Hardware Requirements

- Feetech STS or SCS series servo (e.g., STS3215)
- Feetech URT-1 USB UART adapter (or compatible TTL serial adapter)
- 6-7.4V power supply for servos

## Quick Start

### Controlling a Single Servo

```elixir
# Connect to the servo bus
{:ok, pid} = Feetech.start_link(port: "/dev/ttyUSB0")

# Check servo is responding
{:ok, status} = Feetech.ping(pid, 1)

# Read current position in radians
{:ok, position} = Feetech.read(pid, 1, :present_position)

# Enable torque and move to 90 degrees (π/2 radians)
Feetech.write(pid, 1, :torque_enable, true)
Feetech.write(pid, 1, :goal_position, :math.pi() / 2)

# Read servo status
{:ok, voltage} = Feetech.read(pid, 1, :present_voltage)
{:ok, temperature} = Feetech.read(pid, 1, :present_temperature)
{:ok, load} = Feetech.read(pid, 1, :present_load)

# Disable torque when done
Feetech.write(pid, 1, :torque_enable, false)
```

### Controlling Multiple Servos

```elixir
{:ok, pid} = Feetech.start_link(port: "/dev/ttyUSB0")

# Write positions to multiple servos simultaneously
Feetech.sync_write(pid, :goal_position, [
  {1, 0.0},           # Servo 1 to 0 degrees
  {2, :math.pi() / 2}, # Servo 2 to 90 degrees
  {3, :math.pi()}      # Servo 3 to 180 degrees
])

# Read positions from multiple servos
{:ok, positions} = Feetech.sync_read(pid, [1, 2, 3], :present_position)
```

### Synchronised Movement

For perfectly coordinated multi-servo motion, use buffered writes:

```elixir
# Buffer commands (servos don't move yet)
Feetech.reg_write(pid, 1, :goal_position, :math.pi() / 4)
Feetech.reg_write(pid, 2, :goal_position, :math.pi() / 2)
Feetech.reg_write(pid, 3, :goal_position, 3 * :math.pi() / 4)

# Execute all buffered commands simultaneously
Feetech.action(pid)
```

### Operating Modes

Servos support multiple operating modes:

```elixir
# Unlock EEPROM to change mode
Feetech.write(pid, 1, :lock, false)

# Position mode (default) - servo holds position
Feetech.write(pid, 1, :mode, :position)

# Velocity mode - continuous rotation
Feetech.write(pid, 1, :mode, :velocity)
Feetech.write(pid, 1, :torque_enable, true)
Feetech.write_raw(pid, 1, :goal_speed, 500)  # Set rotation speed

# Step mode - multi-turn positioning
Feetech.write(pid, 1, :mode, :step)

# Lock EEPROM when done
Feetech.write(pid, 1, :lock, true)
```

### Raw vs Converted Values

The driver supports both converted (user-friendly) and raw (register) values:

```elixir
# Converted: position in radians, voltage in volts
{:ok, radians} = Feetech.read(pid, 1, :present_position)
{:ok, volts} = Feetech.read(pid, 1, :present_voltage)

# Raw: position in steps (0-4095), voltage in 0.1V units
{:ok, steps} = Feetech.read_raw(pid, 1, :present_position)
{:ok, decivolts} = Feetech.read_raw(pid, 1, :present_voltage)
```

## Mix Tasks

### Scan for Servos

```bash
# Scan for all connected servos
mix feetech.scan /dev/ttyUSB0

# Scan with verbose output
mix feetech.scan /dev/ttyUSB0 --verbose

# Scan specific ID range
mix feetech.scan /dev/ttyUSB0 --start-id 1 --end-id 10
```

### Set Servo ID

```bash
# Change servo ID from 1 to 5
mix feetech.set_id /dev/ttyUSB0 5

# Change servo with current ID 3 to ID 7
mix feetech.set_id /dev/ttyUSB0 7 --current-id 3

# Use broadcast (only one servo connected)
mix feetech.set_id /dev/ttyUSB0 1 --broadcast
```

### Debug Communication

```bash
# Low-level protocol debugging
mix feetech.debug /dev/ttyUSB0

# Try different baud rates
mix feetech.debug /dev/ttyUSB0 --baud-rate 115200
```

## Available Registers

### EEPROM (Persistent)

| Register | Type | Description |
|----------|------|-------------|
| `:id` | integer | Servo ID (1-253) |
| `:baud_rate` | integer | Communication baud rate |
| `:mode` | atom | Operating mode (`:position`, `:velocity`, `:step`) |
| `:min_angle_limit` | float | Minimum position limit (radians) |
| `:max_angle_limit` | float | Maximum position limit (radians) |
| `:max_temperature` | integer | Temperature limit (°C) |
| `:max_torque` | float | Maximum torque (0.0-1.0) |
| `:position_p_gain` | integer | Position P gain |
| `:position_i_gain` | integer | Position I gain |
| `:position_d_gain` | integer | Position D gain |

### SRAM (Volatile)

| Register | Type | Description |
|----------|------|-------------|
| `:torque_enable` | boolean | Enable/disable torque |
| `:goal_position` | float | Target position (radians) |
| `:goal_speed` | float | Target speed |
| `:goal_time` | integer | Movement time |
| `:acceleration` | integer | Acceleration profile |
| `:lock` | boolean | EEPROM write lock |

### Feedback (Read-only)

| Register | Type | Description |
|----------|------|-------------|
| `:present_position` | float | Current position (radians) |
| `:present_speed` | float | Current speed |
| `:present_load` | float | Current load (%) |
| `:present_voltage` | float | Supply voltage (V) |
| `:present_temperature` | integer | Temperature (°C) |
| `:moving` | boolean | Movement in progress |

## Configuration Options

```elixir
Feetech.start_link(
  port: "/dev/ttyUSB0",        # Serial port (required)
  baud_rate: 1_000_000,        # Baud rate (default: 1M)
  control_table: Feetech.ControlTable.STS3215,  # Servo type (default)
  timeout: 100,                # Response timeout in ms
  name: MyServo                # Optional GenServer name
)
```

## Documentation

Full documentation is available at [HexDocs](https://hexdocs.pm/feetech).

## Licence

Apache 2.0.
