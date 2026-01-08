# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech do
  @moduledoc """
  Driver for Feetech TTL-based serial bus servos.

  This module provides a GenServer-based interface for communicating with
  Feetech servos using their proprietary serial protocol.

  ## Basic Usage

      # Start the driver (defaults to STS3215 control table)
      {:ok, pid} = Feetech.start_link(port: "/dev/ttyUSB0")

      # Check if servo is responding
      {:ok, status} = Feetech.ping(pid, 1)

      # Read current position (radians)
      {:ok, position} = Feetech.read(pid, 1, :present_position)

      # Move to position (radians)
      :ok = Feetech.write(pid, 1, :goal_position, 1.57)

      # Read raw position (steps)
      {:ok, steps} = Feetech.read_raw(pid, 1, :present_position)

  ## Operating Modes

  Servos support multiple operating modes:

    * `:position` - Standard position control (default)
    * `:velocity` - Continuous rotation with speed control
    * `:step` - Stepper mode for multi-turn positioning

  Change modes by writing to the `:mode` register.

  ## Bulk Operations

  For controlling multiple servos simultaneously:

      # Write to multiple servos at once
      Feetech.sync_write(pid, :goal_position, [
        {1, 1.57},
        {2, 0.0},
        {3, -1.57}
      ])

      # Read from multiple servos
      {:ok, positions} = Feetech.sync_read(pid, [1, 2, 3], :present_position)

  ## Buffered Writes

  For synchronized movement across multiple servos:

      # Buffer commands (servos don't move yet)
      Feetech.reg_write(pid, 1, :goal_position, 1.57)
      Feetech.reg_write(pid, 2, :goal_position, 0.0)

      # Execute all buffered commands simultaneously
      Feetech.action(pid)
  """

  use GenServer

  alias Feetech.{ControlTable, Error, Protocol}

  require Feetech.Instruction

  @default_baud_rate 1_000_000
  @default_timeout 100
  @read_chunk_timeout 10

  @type servo_id :: 0..254
  @type register_name :: atom()
  @type option ::
          {:port, String.t()}
          | {:baud_rate, pos_integer()}
          | {:control_table, module()}
          | {:timeout, pos_integer()}
          | {:name, GenServer.name()}

  defmodule State do
    @moduledoc false
    defstruct [:uart, :control_table, :timeout, :buffer]
  end

  @doc """
  Starts the Feetech driver.

  ## Options

    * `:port` - Serial port path (required), e.g., `"/dev/ttyUSB0"`
    * `:baud_rate` - Baud rate, defaults to 1,000,000
    * `:control_table` - Control table module, defaults to `Feetech.ControlTable.STS3215`
    * `:timeout` - Response timeout in ms, defaults to 100
    * `:name` - GenServer name for registration

  ## Examples

      {:ok, pid} = Feetech.start_link(port: "/dev/ttyUSB0")
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Pings a servo to check if it's responding.

  Returns the parsed status from the servo.

  ## Examples

      {:ok, %{errors: [], torque_enabled: true}} = Feetech.ping(pid, 1)
  """
  @spec ping(GenServer.server(), servo_id()) ::
          {:ok, Error.status_info()} | {:error, Error.error()}
  def ping(server, id) do
    GenServer.call(server, {:ping, id})
  end

  @doc """
  Reads a register value with unit conversion.

  The value is converted according to the control table specification
  (e.g., steps to radians for position).

  ## Examples

      {:ok, 1.57} = Feetech.read(pid, 1, :present_position)  # radians
      {:ok, true} = Feetech.read(pid, 1, :torque_enable)     # boolean
  """
  @spec read(GenServer.server(), servo_id(), register_name()) ::
          {:ok, term()} | {:error, Error.error()}
  def read(server, id, register) do
    GenServer.call(server, {:read, id, register, :converted})
  end

  @doc """
  Reads a register value as a raw integer (no conversion).

  ## Examples

      {:ok, 2048} = Feetech.read_raw(pid, 1, :present_position)  # steps
  """
  @spec read_raw(GenServer.server(), servo_id(), register_name()) ::
          {:ok, integer()} | {:error, Error.error()}
  def read_raw(server, id, register) do
    GenServer.call(server, {:read, id, register, :raw})
  end

  @doc """
  Writes a converted value to a register.

  The value is converted from user units (e.g., radians) to raw units
  according to the control table specification.

  By default, this is a fire-and-forget operation. Use `await_response: true`
  to wait for acknowledgement.

  ## Options

    * `:await_response` - Wait for servo response (default: false)

  ## Examples

      :ok = Feetech.write(pid, 1, :goal_position, 1.57)
      {:ok, status} = Feetech.write(pid, 1, :goal_position, 1.57, await_response: true)
  """
  @spec write(GenServer.server(), servo_id(), register_name(), term(), keyword()) ::
          :ok | {:ok, Error.status_info()} | {:error, Error.error()}
  def write(server, id, register, value, opts \\ []) do
    await = Keyword.get(opts, :await_response, false)
    GenServer.call(server, {:write, id, register, value, :converted, await})
  end

  @doc """
  Writes a raw integer value to a register (no conversion).

  ## Examples

      :ok = Feetech.write_raw(pid, 1, :goal_position, 2048)
  """
  @spec write_raw(GenServer.server(), servo_id(), register_name(), integer(), keyword()) ::
          :ok | {:ok, Error.status_info()} | {:error, Error.error()}
  def write_raw(server, id, register, value, opts \\ []) do
    await = Keyword.get(opts, :await_response, false)
    GenServer.call(server, {:write, id, register, value, :raw, await})
  end

  @doc """
  Writes a buffered command that executes on `action/1`.

  Use this to synchronize movement across multiple servos.

  ## Examples

      :ok = Feetech.reg_write(pid, 1, :goal_position, 1.57)
      :ok = Feetech.reg_write(pid, 2, :goal_position, 0.0)
      :ok = Feetech.action(pid)  # Both servos move simultaneously
  """
  @spec reg_write(GenServer.server(), servo_id(), register_name(), term()) ::
          :ok | {:ok, Error.status_info()} | {:error, Error.error()}
  def reg_write(server, id, register, value) do
    GenServer.call(server, {:reg_write, id, register, value})
  end

  @doc """
  Triggers all buffered `reg_write` commands.

  Typically sent to all servos using the broadcast ID.
  """
  @spec action(GenServer.server()) :: :ok
  def action(server) do
    GenServer.cast(server, :action)
  end

  @doc """
  Writes converted values to multiple servos simultaneously.

  ## Examples

      :ok = Feetech.sync_write(pid, :goal_position, [
        {1, 1.57},
        {2, 0.0},
        {3, -1.57}
      ])
  """
  @spec sync_write(GenServer.server(), register_name(), [{servo_id(), term()}]) ::
          :ok | {:error, Error.error()}
  def sync_write(server, register, servo_values) do
    GenServer.cast(server, {:sync_write, register, servo_values, :converted})
    :ok
  end

  @doc """
  Writes raw values to multiple servos simultaneously.
  """
  @spec sync_write_raw(GenServer.server(), register_name(), [{servo_id(), integer()}]) ::
          :ok | {:error, Error.error()}
  def sync_write_raw(server, register, servo_values) do
    GenServer.cast(server, {:sync_write, register, servo_values, :raw})
    :ok
  end

  @doc """
  Reads converted values from multiple servos.

  Returns values in the same order as the ID list.

  ## Examples

      {:ok, [1.57, 0.0, -1.57]} = Feetech.sync_read(pid, [1, 2, 3], :present_position)
  """
  @spec sync_read(GenServer.server(), [servo_id()], register_name()) ::
          {:ok, [term()]} | {:error, Error.error()}
  def sync_read(server, ids, register) do
    GenServer.call(server, {:sync_read, ids, register, :converted})
  end

  @doc """
  Reads raw values from multiple servos.
  """
  @spec sync_read_raw(GenServer.server(), [servo_id()], register_name()) ::
          {:ok, [integer()]} | {:error, Error.error()}
  def sync_read_raw(server, ids, register) do
    GenServer.call(server, {:sync_read, ids, register, :raw})
  end

  @doc """
  Resets a servo's control table to factory defaults.
  """
  @spec recovery(GenServer.server(), servo_id()) ::
          {:ok, Error.status_info()} | {:error, Error.error()}
  def recovery(server, id) do
    GenServer.call(server, {:recovery, id})
  end

  @doc """
  Resets a servo's state (rotation count for multi-turn mode).
  """
  @spec reset(GenServer.server(), servo_id()) ::
          {:ok, Error.status_info()} | {:error, Error.error()}
  def reset(server, id) do
    GenServer.call(server, {:reset, id})
  end

  @doc """
  Closes the UART connection and stops the driver.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    control_table = Keyword.get(opts, :control_table, Feetech.ControlTable.STS3215)
    baud_rate = Keyword.get(opts, :baud_rate, @default_baud_rate)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {:ok, uart} = Circuits.UART.start_link()

    uart_opts = [
      speed: baud_rate,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      active: false
    ]

    case Circuits.UART.open(uart, port, uart_opts) do
      :ok ->
        state = %State{
          uart: uart,
          control_table: control_table,
          timeout: timeout,
          buffer: <<>>
        }

        {:ok, state}

      {:error, reason} ->
        Circuits.UART.stop(uart)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:ping, id}, _from, state) do
    packet = Protocol.build_ping(id)
    result = send_and_receive(state, packet)
    {:reply, result, state}
  end

  def handle_call({:read, id, register, mode}, _from, state) do
    with {:ok, {address, length, _conversion}} <-
           ControlTable.get_register(state.control_table, register),
         packet = Protocol.build_read(id, address, length),
         {:ok, response} <- send_and_receive(state, packet) do
      value =
        case mode do
          :converted -> decode_value(state.control_table, register, response.params)
          :raw -> ControlTable.decode_raw(response.params)
        end

      {:reply, {:ok, value}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:write, id, register, value, mode, await}, _from, state) do
    with {:ok, {address, _length, _conversion}} <-
           ControlTable.get_register(state.control_table, register),
         {:ok, data} <- encode_value(state.control_table, register, value, mode) do
      packet = Protocol.build_write(id, address, data)

      # Always read the response to clear the buffer, even if we don't need it
      result = send_and_receive(state, packet)

      if await do
        {:reply, result, state}
      else
        {:reply, :ok, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reg_write, id, register, value}, _from, state) do
    with {:ok, {address, _length, _conversion}} <-
           ControlTable.get_register(state.control_table, register),
         {:ok, data} <- ControlTable.encode(state.control_table, register, value) do
      packet = Protocol.build_reg_write(id, address, data)
      result = send_and_receive(state, packet)
      {:reply, result, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:sync_read, ids, register, mode}, _from, state) do
    case ControlTable.get_register(state.control_table, register) do
      {:ok, {address, length, _conversion}} ->
        result = do_sync_read(state, ids, register, mode, address, length)
        {:reply, result, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:recovery, id}, _from, state) do
    packet = Protocol.build_recovery(id)
    result = send_and_receive(state, packet)
    {:reply, result, state}
  end

  def handle_call({:reset, id}, _from, state) do
    packet = Protocol.build_reset(id)
    result = send_and_receive(state, packet)
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:action, state) do
    packet = Protocol.build_action()
    send_packet(state, packet)
    {:noreply, state}
  end

  def handle_cast({:sync_write, register, servo_values, mode}, state) do
    with {:ok, {address, length, _conversion}} <-
           ControlTable.get_register(state.control_table, register) do
      data =
        Enum.map(servo_values, fn {id, value} ->
          {:ok, encoded} = encode_value(state.control_table, register, value, mode)
          {id, encoded}
        end)

      packet = Protocol.build_sync_write(address, length, data)
      send_packet(state, packet)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.uart do
      Circuits.UART.close(state.uart)
      Circuits.UART.stop(state.uart)
    end

    :ok
  end

  defp do_sync_read(state, ids, register, mode, address, length) do
    packet = Protocol.build_sync_read(address, length, ids)
    send_packet(state, packet)

    results = Enum.map(ids, fn _id -> read_sync_response(state, register, mode) end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      values = Enum.map(results, fn {:ok, v} -> v end)
      {:ok, values}
    else
      {:error, :partial_read}
    end
  end

  defp read_sync_response(state, register, mode) do
    case receive_response(state) do
      {:ok, response} ->
        value = decode_response_value(state.control_table, register, response.params, mode)
        {:ok, value}

      error ->
        error
    end
  end

  defp decode_response_value(control_table, register, params, :converted) do
    decode_value(control_table, register, params)
  end

  defp decode_response_value(_control_table, _register, params, :raw) do
    ControlTable.decode_raw(params)
  end

  defp send_packet(state, packet) do
    Circuits.UART.write(state.uart, packet)
  end

  defp send_and_receive(state, packet) do
    send_packet(state, packet)
    receive_response(state)
  end

  defp receive_response(state) do
    case read_packet(state.uart, state.timeout, state.buffer) do
      {:ok, packet, _remaining} ->
        case Protocol.parse_response(packet) do
          {:ok, response} ->
            {:ok, Error.parse_status(response.status) |> Map.put(:params, response.params)}

          error ->
            error
        end

      {:error, :timeout} ->
        {:error, :no_response}

      error ->
        error
    end
  end

  defp read_packet(uart, timeout, buffer) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_read_packet(uart, deadline, buffer)
  end

  defp do_read_packet(uart, deadline, buffer) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 do
      {:error, :timeout}
    else
      read_timeout = min(remaining_time, @read_chunk_timeout)
      do_read_uart(uart, deadline, buffer, read_timeout)
    end
  end

  defp do_read_uart(uart, deadline, buffer, read_timeout) do
    case Circuits.UART.read(uart, read_timeout) do
      {:ok, <<>>} ->
        try_extract_or_continue(uart, deadline, buffer)

      {:ok, data} ->
        try_extract_or_continue(uart, deadline, buffer <> data)

      {:error, _} = error ->
        error
    end
  end

  defp try_extract_or_continue(uart, deadline, buffer) do
    case Protocol.extract_packet(buffer) do
      {:ok, packet, remaining} -> {:ok, packet, remaining}
      {:incomplete, _} -> do_read_packet(uart, deadline, buffer)
    end
  end

  defp encode_value(control_table, register, value, :converted) do
    ControlTable.encode(control_table, register, value)
  end

  defp encode_value(control_table, register, value, :raw) do
    ControlTable.encode_raw(control_table, register, value)
  end

  defp decode_value(control_table, register, data) do
    {:ok, value} = ControlTable.decode(control_table, register, data)
    value
  end
end
