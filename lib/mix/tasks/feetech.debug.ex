# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Feetech.Debug do
  @shortdoc "Debug servo communication"
  @moduledoc """
  Low-level debug tool for Feetech servo communication.

  ## Usage

      mix feetech.debug PORT [OPTIONS]

  ## Options

    * `--baud-rate`, `-b` - Baud rate (default: 1000000)
    * `--id`, `-i` - Servo ID to ping (default: 1)
    * `--timeout`, `-t` - Response timeout in ms (default: 500)
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    baud_rate: :integer,
    id: :integer,
    timeout: :integer
  ]

  @aliases [
    b: :baud_rate,
    i: :id,
    t: :timeout
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    case args do
      [port] ->
        debug_servo(port, opts)

      _ ->
        Mix.shell().error("Usage: mix feetech.debug PORT [OPTIONS]")
        exit({:shutdown, 1})
    end
  end

  defp debug_servo(port, opts) do
    baud_rate = Keyword.get(opts, :baud_rate, 1_000_000)
    servo_id = Keyword.get(opts, :id, 1)
    timeout = Keyword.get(opts, :timeout, 500)

    Mix.shell().info("Opening #{port} at #{baud_rate} baud...")

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
        Mix.shell().info("Port opened successfully")
        do_debug(uart, servo_id, timeout)
        Circuits.UART.close(uart)

      {:error, reason} ->
        Mix.shell().error("Failed to open port: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp do_debug(uart, servo_id, timeout) do
    send_ping(uart, servo_id, timeout, true)
    Mix.shell().info("\n--- Trying broadcast ping (ID 0xFE) ---")
    send_ping(uart, 0xFE, timeout, false)
  end

  defp send_ping(uart, id, timeout, show_troubleshooting) do
    packet = Feetech.Protocol.build_ping(id)

    Mix.shell().info("\nSending PING to ID #{id}")
    Mix.shell().info("TX: #{inspect(packet, base: :hex)}")

    :ok = Circuits.UART.write(uart, packet)
    Process.sleep(10)

    Mix.shell().info("Waiting for response (#{timeout}ms timeout)...")
    handle_ping_response(uart, timeout, show_troubleshooting)
  end

  defp handle_ping_response(uart, timeout, show_troubleshooting) do
    case Circuits.UART.read(uart, timeout) do
      {:ok, <<>>} ->
        Mix.shell().info("RX: (empty - no response)")
        if show_troubleshooting, do: suggest_troubleshooting()

      {:ok, data} ->
        print_response(data)

      {:error, reason} ->
        Mix.shell().error("Read error: #{inspect(reason)}")
    end
  end

  defp print_response(data) do
    Mix.shell().info("RX: #{inspect(data, base: :hex)}")
    Mix.shell().info("RX (decimal): #{inspect(:binary.bin_to_list(data))}")

    case Feetech.Protocol.parse_response(data) do
      {:ok, response} ->
        Mix.shell().info("Parsed response: ID=#{response.id}, Status=#{response.status}")

      {:error, reason} ->
        Mix.shell().info("Failed to parse: #{inspect(reason)}")
    end
  end

  defp suggest_troubleshooting do
    Mix.shell().info("""

    Troubleshooting steps:
    1. Check physical connections (TX/RX wiring, power)
    2. Verify servo has power (LED should blink on startup)
    3. Try different baud rates:
       mix feetech.debug #{get_port()} --baud-rate 115200
       mix feetech.debug #{get_port()} --baud-rate 500000
    4. Try broadcast ID to find any servo:
       (already attempted above)
    5. Check if servo ID is different:
       mix feetech.debug #{get_port()} --id 2
    """)
  end

  defp get_port do
    case System.argv() do
      [_, port | _] -> port
      _ -> "/dev/ttyUSB0"
    end
  end
end
