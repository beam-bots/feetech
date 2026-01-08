# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Feetech.SetId do
  @shortdoc "Set a Feetech servo's ID"
  @moduledoc """
  Sets the ID of a Feetech servo.

  ## Usage

      mix feetech.set_id PORT NEW_ID [OPTIONS]

  ## Arguments

    * `PORT` - Serial port (e.g., /dev/ttyUSB0)
    * `NEW_ID` - New servo ID (1-253)

  ## Options

    * `--current-id`, `-c` - Current servo ID (default: 1)
    * `--baud-rate`, `-b` - Baud rate (default: 1000000)
    * `--broadcast`, `-B` - Use broadcast ID (0xFE) to address any servo.
      Only use when a single servo is connected.

  ## Examples

      # Set servo with ID 1 to ID 5
      mix feetech.set_id /dev/ttyUSB0 5

      # Set servo with ID 3 to ID 7
      mix feetech.set_id /dev/ttyUSB0 7 --current-id 3

      # Set any connected servo to ID 1 (only one servo connected)
      mix feetech.set_id /dev/ttyUSB0 1 --broadcast

      # Use different baud rate
      mix feetech.set_id /dev/ttyUSB0 5 --baud-rate 115200

  ## Notes

  The servo's EEPROM lock will be temporarily disabled to write the ID,
  then re-enabled after. The servo will respond with its new ID after
  the change.

  When using `--broadcast`, ensure only ONE servo is connected to avoid
  setting multiple servos to the same ID.
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    current_id: :integer,
    baud_rate: :integer,
    broadcast: :boolean
  ]

  @aliases [
    c: :current_id,
    b: :baud_rate,
    B: :broadcast
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    case args do
      [port, new_id_str] ->
        new_id = parse_id!(new_id_str, "new ID")
        current_id = get_current_id(opts)
        baud_rate = Keyword.get(opts, :baud_rate, 1_000_000)

        set_servo_id(port, current_id, new_id, baud_rate)

      _ ->
        Mix.shell().error("Usage: mix feetech.set_id PORT NEW_ID [OPTIONS]")
        Mix.shell().error("Run `mix help feetech.set_id` for more information.")
        exit({:shutdown, 1})
    end
  end

  defp get_current_id(opts) do
    cond do
      Keyword.get(opts, :broadcast) -> 0xFE
      Keyword.has_key?(opts, :current_id) -> opts[:current_id]
      true -> 1
    end
  end

  defp parse_id!(str, name) do
    case Integer.parse(str) do
      {id, ""} when id >= 1 and id <= 253 ->
        id

      {id, ""} when id < 1 or id > 253 ->
        Mix.shell().error("Error: #{name} must be between 1 and 253, got #{id}")
        exit({:shutdown, 1})

      _ ->
        Mix.shell().error("Error: #{name} must be an integer, got #{inspect(str)}")
        exit({:shutdown, 1})
    end
  end

  defp set_servo_id(port, current_id, new_id, baud_rate) do
    Mix.shell().info("Connecting to #{port} at #{baud_rate} baud...")

    case Feetech.start_link(port: port, baud_rate: baud_rate) do
      {:ok, pid} ->
        try do
          do_set_id(pid, current_id, new_id)
        after
          Feetech.stop(pid)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to connect: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp do_set_id(pid, current_id, new_id) do
    id_label = if current_id == 0xFE, do: "broadcast", else: "ID #{current_id}"
    Mix.shell().info("Targeting servo via #{id_label}")

    ping_servo!(pid, current_id)
    unlock_eeprom!(pid, current_id)
    write_new_id!(pid, current_id, new_id)
    Process.sleep(50)
    lock_eeprom(pid, new_id)
    verify_new_id(pid, new_id)
  end

  defp ping_servo!(pid, id) do
    Mix.shell().info("Pinging servo...")

    case Feetech.ping(pid, id) do
      {:ok, _response} ->
        Mix.shell().info("Servo responded")

      {:error, :no_response} ->
        Mix.shell().error("No response from servo. Check connection and ID.")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Ping failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp unlock_eeprom!(pid, id) do
    Mix.shell().info("Unlocking EEPROM...")

    case Feetech.write_raw(pid, id, :lock, 0) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Failed to unlock EEPROM: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp write_new_id!(pid, current_id, new_id) do
    Mix.shell().info("Setting ID to #{new_id}...")

    case Feetech.write_raw(pid, current_id, :id, new_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Failed to write ID: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp lock_eeprom(pid, id) do
    Mix.shell().info("Locking EEPROM...")

    case Feetech.write_raw(pid, id, :lock, 1) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.shell().info("Note: Could not lock EEPROM: #{inspect(reason)}")
    end
  end

  defp verify_new_id(pid, new_id) do
    Mix.shell().info("Verifying new ID...")

    case Feetech.ping(pid, new_id) do
      {:ok, _response} ->
        Mix.shell().info("Success! Servo now responds as ID #{new_id}")

      {:error, reason} ->
        Mix.shell().info(
          "Note: Could not verify new ID (#{inspect(reason)}). " <>
            "The ID may still have been set correctly."
        )
    end
  end
end
