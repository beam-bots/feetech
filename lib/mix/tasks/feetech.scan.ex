# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Feetech.Scan do
  @shortdoc "Scan for connected Feetech servos"
  @moduledoc """
  Scans a serial port for connected Feetech servos and displays their status
  and configuration.

  ## Usage

      mix feetech.scan PORT [OPTIONS]

  ## Arguments

    * `PORT` - Serial port (e.g., /dev/ttyUSB0)

  ## Options

    * `--baud-rate`, `-b` - Baud rate (default: 1000000)
    * `--start-id`, `-s` - Start ID for scan range (default: 1)
    * `--end-id`, `-e` - End ID for scan range (default: 253)
    * `--timeout`, `-t` - Response timeout in ms (default: 50)
    * `--verbose`, `-v` - Show detailed information for each servo

  ## Examples

      # Scan all IDs on default baud rate
      mix feetech.scan /dev/ttyUSB0

      # Scan specific ID range
      mix feetech.scan /dev/ttyUSB0 --start-id 1 --end-id 10

      # Scan with verbose output
      mix feetech.scan /dev/ttyUSB0 --verbose

      # Scan at different baud rate
      mix feetech.scan /dev/ttyUSB0 --baud-rate 115200
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    baud_rate: :integer,
    start_id: :integer,
    end_id: :integer,
    timeout: :integer,
    verbose: :boolean
  ]

  @aliases [
    b: :baud_rate,
    s: :start_id,
    e: :end_id,
    t: :timeout,
    v: :verbose
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    case args do
      [port] ->
        scan_servos(port, opts)

      _ ->
        Mix.shell().error("Usage: mix feetech.scan PORT [OPTIONS]")
        Mix.shell().error("Run `mix help feetech.scan` for more information.")
        exit({:shutdown, 1})
    end
  end

  defp scan_servos(port, opts) do
    baud_rate = Keyword.get(opts, :baud_rate, 1_000_000)
    start_id = Keyword.get(opts, :start_id, 1)
    end_id = Keyword.get(opts, :end_id, 253)
    timeout = Keyword.get(opts, :timeout, 50)
    verbose = Keyword.get(opts, :verbose, false)

    Mix.shell().info("Connecting to #{port} at #{format_baud(baud_rate)}...")

    case Feetech.start_link(port: port, baud_rate: baud_rate, timeout: timeout) do
      {:ok, pid} ->
        try do
          do_scan(pid, start_id, end_id, verbose)
        after
          Feetech.stop(pid)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to connect: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp do_scan(pid, start_id, end_id, verbose) do
    Mix.shell().info("Scanning IDs #{start_id}-#{end_id}...\n")

    servos =
      start_id..end_id
      |> Enum.reduce([], fn id, acc ->
        case Feetech.ping(pid, id) do
          {:ok, _response} ->
            servo_info = read_servo_info(pid, id)
            [{id, servo_info} | acc]

          {:error, _} ->
            acc
        end
      end)
      |> Enum.reverse()

    case servos do
      [] ->
        Mix.shell().info("No servos found.")

      _ ->
        Mix.shell().info("Found #{length(servos)} servo(s):\n")
        Enum.each(servos, &print_servo_info(&1, verbose))
    end
  end

  defp read_servo_info(pid, id) do
    %{
      firmware: read_firmware_version(pid, id),
      servo_version: read_servo_version(pid, id),
      baud_rate: read_register(pid, id, :baud_rate),
      mode: read_register(pid, id, :mode),
      torque_enabled: read_register(pid, id, :torque_enable),
      position: read_register(pid, id, :present_position),
      speed: read_register(pid, id, :present_speed),
      load: read_register(pid, id, :present_load),
      voltage: read_register(pid, id, :present_voltage),
      temperature: read_register(pid, id, :present_temperature),
      moving: read_register(pid, id, :moving),
      min_angle: read_register(pid, id, :min_angle_limit),
      max_angle: read_register(pid, id, :max_angle_limit),
      max_torque: read_register(pid, id, :max_torque),
      position_p: read_register_raw(pid, id, :position_p_gain),
      position_d: read_register_raw(pid, id, :position_d_gain),
      position_i: read_register_raw(pid, id, :position_i_gain),
      hardware_error: read_register_raw(pid, id, :hardware_error_status)
    }
  end

  defp read_firmware_version(pid, id) do
    main = read_register_raw(pid, id, :firmware_version_main)
    sub = read_register_raw(pid, id, :firmware_version_sub)
    format_version(main, sub)
  end

  defp read_servo_version(pid, id) do
    main = read_register_raw(pid, id, :servo_version_main)
    sub = read_register_raw(pid, id, :servo_version_sub)
    format_version(main, sub)
  end

  defp format_version({:ok, main}, {:ok, sub}), do: "#{main}.#{sub}"
  defp format_version(_, _), do: "unknown"

  defp read_register(pid, id, register) do
    case Feetech.read(pid, id, register) do
      {:ok, value} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  defp read_register_raw(pid, id, register) do
    case Feetech.read_raw(pid, id, register) do
      {:ok, value} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  defp print_servo_info({id, info}, verbose) do
    Mix.shell().info(header_line(id, info))

    if verbose do
      print_verbose_info(info)
    end

    Mix.shell().info("")
  end

  defp header_line(id, info) do
    parts = [
      "ID #{id}",
      firmware_str(info.firmware),
      mode_str(info.mode),
      torque_str(info.torque_enabled),
      position_str(info.position),
      voltage_str(info.voltage),
      temp_str(info.temperature)
    ]

    "  " <> Enum.join(parts, " | ")
  end

  defp firmware_str(version), do: "FW #{version}"

  defp mode_str({:ok, mode}), do: "#{mode}"
  defp mode_str(_), do: "mode?"

  defp torque_str({:ok, true}), do: "torque ON"
  defp torque_str({:ok, false}), do: "torque OFF"
  defp torque_str(_), do: "torque?"

  defp position_str({:ok, pos}), do: "pos #{format_angle(pos)}"
  defp position_str(_), do: "pos?"

  defp voltage_str({:ok, v}), do: "#{:erlang.float_to_binary(v, decimals: 1)}V"
  defp voltage_str(_), do: "?V"

  defp temp_str({:ok, t}), do: "#{t}C"
  defp temp_str(_), do: "?C"

  defp print_verbose_info(info) do
    Mix.shell().info("    Servo version: #{info.servo_version}")
    Mix.shell().info("    Baud rate: #{format_baud_value(info.baud_rate)}")
    print_if_ok("    Speed: ", info.speed, &format_speed/1)
    print_if_ok("    Load: ", info.load, &format_load/1)
    print_if_ok("    Moving: ", info.moving, &to_string/1)
    print_angle_limits(info.min_angle, info.max_angle)
    print_if_ok("    Max torque: ", info.max_torque, &format_percent/1)
    print_pid_gains(info)
    print_hardware_errors(info.hardware_error)
  end

  defp print_if_ok(label, {:ok, value}, formatter) do
    Mix.shell().info(label <> formatter.(value))
  end

  defp print_if_ok(_, _, _), do: :ok

  defp print_angle_limits({:ok, min}, {:ok, max}) do
    Mix.shell().info("    Angle limits: #{format_angle(min)} to #{format_angle(max)}")
  end

  defp print_angle_limits(_, _), do: :ok

  defp print_pid_gains(info) do
    case {info.position_p, info.position_i, info.position_d} do
      {{:ok, p}, {:ok, i}, {:ok, d}} ->
        Mix.shell().info("    PID gains: P=#{p} I=#{i} D=#{d}")

      _ ->
        :ok
    end
  end

  defp print_hardware_errors({:ok, 0}), do: :ok

  defp print_hardware_errors({:ok, status}) do
    errors = Feetech.Error.parse_status(status)

    if errors.errors != [] do
      error_str = Enum.map_join(errors.errors, ", ", &to_string/1)
      Mix.shell().info("    Hardware errors: #{error_str}")
    end
  end

  defp print_hardware_errors(_), do: :ok

  defp format_angle(radians) do
    degrees = radians * 180 / :math.pi()
    "#{:erlang.float_to_binary(degrees, decimals: 1)}deg"
  end

  defp format_speed(rad_per_sec) do
    rpm = rad_per_sec * 60 / (2 * :math.pi())
    "#{:erlang.float_to_binary(rpm, decimals: 1)} RPM"
  end

  defp format_load(load_percent) do
    "#{:erlang.float_to_binary(load_percent, decimals: 1)}%"
  end

  defp format_percent(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 1)}%"
  end

  defp format_baud(rate) when rate >= 1_000_000, do: "#{div(rate, 1_000_000)}M baud"
  defp format_baud(rate) when rate >= 1000, do: "#{div(rate, 1000)}k baud"
  defp format_baud(rate), do: "#{rate} baud"

  defp format_baud_value({:ok, rate}), do: format_baud(rate)
  defp format_baud_value(_), do: "unknown"
end
