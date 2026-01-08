<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

Feetech is an Elixir driver for Feetech TTL-based serial bus servos (STS/SCS series).
It provides a GenServer-based interface for communicating with servos using the Feetech
proprietary serial protocol.

This is a standalone driver library (similar to `robotis` for Dynamixel servos). It is
designed to be used directly or integrated into higher-level frameworks like Beam Bots.

## Build and Test Commands

```bash
mix check --no-retry    # Run all checks (compile, test, format, credo, dialyzer, reuse)
mix test                # Run unit tests
mix test --include integration  # Run all tests including hardware tests
mix test path/to/test.exs:42    # Run single test at line
mix format              # Format code
```

The project uses `ex_check` - always prefer `mix check --no-retry` over running individual tools.

## Architecture

### Module Structure

```
Feetech (GenServer)
    |
    +-- Protocol (packet building/parsing)
    |
    +-- ControlTable (behaviour)
    |       |
    |       +-- STS3215 (register definitions)
    |
    +-- Instruction (protocol constants)
    |
    +-- Error (error parsing)
```

### Key Modules

- **Feetech** (`lib/feetech.ex`) - Main GenServer managing UART connection. Provides
  read/write operations with unit conversion (radians) and raw (steps) variants.
  Supports sync_read/sync_write for bulk operations and reg_write/action for
  synchronised movement.

- **Protocol** (`lib/feetech/protocol.ex`) - Pure functions for building and parsing
  Feetech protocol packets. Handles checksum calculation, packet framing (0xFF 0xFF
  header), and little-endian integer encoding.

- **ControlTable** (`lib/feetech/control_table.ex`) - Behaviour defining the contract
  for servo-specific register maps. Provides encode/decode functions for converting
  between user units (radians, booleans) and raw register values.

- **ControlTable.STS3215** (`lib/feetech/control_table/sts3215.ex`) - Register
  definitions for STS3215 and compatible STS/SCS series servos. Defines addresses,
  lengths, and conversions for all supported registers.

- **Instruction** (`lib/feetech/instruction.ex`) - Constants for protocol instruction
  codes (ping, read, write, sync_read, sync_write, reg_write, action, etc.).

- **Error** (`lib/feetech/error.ex`) - Parsing of status byte from servo responses.
  Extracts error flags (voltage, temperature, overload) and torque state.

### Mix Tasks

- **mix feetech.scan** - Scan for connected servos with status display
- **mix feetech.set_id** - Change a servo's ID number
- **mix feetech.debug** - Low-level protocol debugging

## Protocol Details

### Packet Format

```
Header (2) | ID (1) | Length (1) | Instruction (1) | Params (n) | Checksum (1)
0xFF 0xFF  | 0x01   | 0x04       | 0x02            | ...        | ~(sum) & 0xFF
```

- Header: Always `0xFF 0xFF`
- Length: Number of bytes after Length field (Instruction + Params + Checksum)
- Checksum: Bitwise NOT of sum of ID, Length, Instruction, and Params

### Key Differences from Dynamixel

1. Simpler 2-byte header (vs 4-byte in Protocol 2.0)
2. Simple checksum (bitwise NOT of sum) vs CRC16
3. 1-byte length field vs 2-byte
4. No byte stuffing required
5. Little-endian for multi-byte values (same as Dynamixel)

## Testing

### Unit Tests

Unit tests use Mimic to mock `Circuits.UART`. Run with `mix test`.

### Integration Tests

Hardware tests are tagged with `@tag :integration` and excluded by default.
Run with `mix test --include integration`.

Requirements:
- Feetech STS/SCS series servo (tested with STS3215)
- Feetech URT-1 USB adapter or compatible TTL serial adapter
- 6-7.4V power supply

Set `FEETECH_PORT` and `FEETECH_SERVO_ID` environment variables:

```bash
FEETECH_PORT=/dev/ttyUSB0 FEETECH_SERVO_ID=1 mix test --include integration
```

## Adding New Control Tables

To support a new servo model:

1. Create `lib/feetech/control_table/your_model.ex`
2. Implement the `Feetech.ControlTable` behaviour
3. Define `registers/0` returning a map of register definitions
4. Each register: `{address, length, conversion}`

Example:

```elixir
defmodule Feetech.ControlTable.YourModel do
  @behaviour Feetech.ControlTable

  @impl true
  def registers do
    %{
      present_position: {56, 2, :position},
      goal_position: {42, 2, :position},
      # ...
    }
  end

  @impl true
  def model_name, do: "Your Model"
end
```

## Dependencies

- `circuits_uart` - Serial port communication

## Hardware Notes

- Default baud rate: 1,000,000 bps
- STS3215: 4096 steps per revolution, 12-bit magnetic encoder
- Broadcast ID: 254 (0xFE)
- EEPROM registers require unlocking `:lock` register before writing
