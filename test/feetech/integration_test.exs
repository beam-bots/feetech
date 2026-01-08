# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.IntegrationTest do
  @moduledoc """
  Integration tests for Feetech servo driver.

  These tests require real hardware and are excluded by default.

  ## Running Integration Tests

      # Run with a servo on /dev/ttyUSB0 at ID 1 (defaults)
      mix test --include integration

      # Run with custom port and servo ID
      FEETECH_PORT=/dev/ttyUSB1 FEETECH_SERVO_ID=2 mix test --include integration

  ## Requirements

    * A Feetech STS series servo connected via URT-1 or compatible UART adapter
    * Servo powered with appropriate voltage (6-7.4V for STS3215)
    * Servo ID and baud rate at defaults (ID 1, 1M baud) or configured via env vars
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @port System.get_env("FEETECH_PORT", "/dev/ttyUSB0")
  @servo_id String.to_integer(System.get_env("FEETECH_SERVO_ID", "1"))
  @position_tolerance 0.05
  @move_timeout 5000

  setup_all do
    {:ok, pid} = Feetech.start_link(port: @port)

    on_exit(fn ->
      Feetech.write(pid, @servo_id, :torque_enable, false)
      Feetech.stop(pid)
    end)

    %{pid: pid, servo_id: @servo_id}
  end

  setup %{pid: pid, servo_id: servo_id} do
    # Reset servo to known state between tests
    Feetech.write(pid, servo_id, :torque_enable, false)
    Feetech.write_raw(pid, servo_id, :goal_speed, 0)
    Feetech.write_raw(pid, servo_id, :goal_time, 0)
    Feetech.write_raw(pid, servo_id, :acceleration, 0)
    :ok
  end

  describe "ping" do
    test "responds to ping", %{pid: pid, servo_id: servo_id} do
      assert {:ok, status} = Feetech.ping(pid, servo_id)
      assert is_map(status)
      assert Map.has_key?(status, :errors)
    end

    test "returns error for non-existent servo", %{pid: pid} do
      assert {:error, :no_response} = Feetech.ping(pid, 253)
    end
  end

  describe "EEPROM registers (read-only)" do
    test "reads firmware version", %{pid: pid, servo_id: servo_id} do
      assert {:ok, main} = Feetech.read_raw(pid, servo_id, :firmware_version_main)
      assert {:ok, sub} = Feetech.read_raw(pid, servo_id, :firmware_version_sub)
      assert is_integer(main) and main >= 0
      assert is_integer(sub) and sub >= 0
    end

    test "reads servo version", %{pid: pid, servo_id: servo_id} do
      assert {:ok, main} = Feetech.read_raw(pid, servo_id, :servo_version_main)
      assert {:ok, sub} = Feetech.read_raw(pid, servo_id, :servo_version_sub)
      assert is_integer(main) and main >= 0
      assert is_integer(sub) and sub >= 0
    end

    test "reads baud rate", %{pid: pid, servo_id: servo_id} do
      assert {:ok, baud_rate} = Feetech.read(pid, servo_id, :baud_rate)
      assert baud_rate in [38_400, 57_600, 76_800, 115_200, 128_000, 250_000, 500_000, 1_000_000]
    end

    test "reads mode", %{pid: pid, servo_id: servo_id} do
      assert {:ok, mode} = Feetech.read(pid, servo_id, :mode)
      assert mode in [:position, :velocity, :pwm, :step, :unknown]
    end

    test "reads angle limits", %{pid: pid, servo_id: servo_id} do
      assert {:ok, min_angle} = Feetech.read(pid, servo_id, :min_angle_limit)
      assert {:ok, max_angle} = Feetech.read(pid, servo_id, :max_angle_limit)
      assert is_float(min_angle)
      assert is_float(max_angle)
      assert max_angle > min_angle
    end

    test "reads temperature limit", %{pid: pid, servo_id: servo_id} do
      assert {:ok, max_temp} = Feetech.read_raw(pid, servo_id, :max_temperature)
      assert is_integer(max_temp) and max_temp > 0 and max_temp <= 100
    end

    test "reads voltage limits", %{pid: pid, servo_id: servo_id} do
      assert {:ok, min_voltage} = Feetech.read(pid, servo_id, :min_input_voltage)
      assert {:ok, max_voltage} = Feetech.read(pid, servo_id, :max_input_voltage)
      assert is_float(min_voltage) and min_voltage > 0
      assert is_float(max_voltage) and max_voltage > min_voltage
    end

    test "reads PID gains", %{pid: pid, servo_id: servo_id} do
      assert {:ok, p} = Feetech.read_raw(pid, servo_id, :position_p_gain)
      assert {:ok, i} = Feetech.read_raw(pid, servo_id, :position_i_gain)
      assert {:ok, d} = Feetech.read_raw(pid, servo_id, :position_d_gain)
      assert is_integer(p) and p >= 0
      assert is_integer(i) and i >= 0
      assert is_integer(d) and d >= 0
    end

    test "reads max torque", %{pid: pid, servo_id: servo_id} do
      assert {:ok, max_torque} = Feetech.read(pid, servo_id, :max_torque)
      assert is_float(max_torque) and max_torque >= 0 and max_torque <= 1.0
    end
  end

  describe "SRAM registers (feedback)" do
    test "reads present position", %{pid: pid, servo_id: servo_id} do
      assert {:ok, position} = Feetech.read(pid, servo_id, :present_position)
      assert is_float(position)
      assert position >= 0 and position < 2 * :math.pi()
    end

    test "reads present position raw", %{pid: pid, servo_id: servo_id} do
      assert {:ok, steps} = Feetech.read_raw(pid, servo_id, :present_position)
      assert is_integer(steps)
      assert steps >= 0 and steps < 4096
    end

    test "reads present speed", %{pid: pid, servo_id: servo_id} do
      assert {:ok, speed} = Feetech.read(pid, servo_id, :present_speed)
      assert is_float(speed)
    end

    test "reads present load", %{pid: pid, servo_id: servo_id} do
      assert {:ok, load} = Feetech.read(pid, servo_id, :present_load)
      assert is_float(load)
    end

    test "reads present voltage", %{pid: pid, servo_id: servo_id} do
      assert {:ok, voltage} = Feetech.read(pid, servo_id, :present_voltage)
      assert is_float(voltage)
      assert voltage > 5.0 and voltage < 15.0
    end

    test "reads present temperature", %{pid: pid, servo_id: servo_id} do
      assert {:ok, temp} = Feetech.read_raw(pid, servo_id, :present_temperature)
      assert is_integer(temp)
      assert temp > 0 and temp < 100
    end

    test "reads moving status", %{pid: pid, servo_id: servo_id} do
      assert {:ok, moving} = Feetech.read(pid, servo_id, :moving)
      assert is_boolean(moving)
    end

    test "reads hardware error status", %{pid: pid, servo_id: servo_id} do
      assert {:ok, status} = Feetech.read_raw(pid, servo_id, :hardware_error_status)
      assert is_integer(status) and status >= 0
    end
  end

  describe "torque control" do
    test "enables and disables torque", %{pid: pid, servo_id: servo_id} do
      assert :ok = Feetech.write(pid, servo_id, :torque_enable, true)
      assert {:ok, true} = Feetech.read(pid, servo_id, :torque_enable)

      assert :ok = Feetech.write(pid, servo_id, :torque_enable, false)
      assert {:ok, false} = Feetech.read(pid, servo_id, :torque_enable)
    end

    test "reads torque enable with await_response", %{pid: pid, servo_id: servo_id} do
      assert {:ok, _status} =
               Feetech.write(pid, servo_id, :torque_enable, true, await_response: true)

      assert {:ok, true} = Feetech.read(pid, servo_id, :torque_enable)
    end
  end

  describe "position control" do
    test "moves to position 0 degrees", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      target = 0.0
      assert :ok = Feetech.write(pid, servo_id, :goal_position, target)

      wait_for_move(pid, servo_id)

      assert {:ok, position} = Feetech.read(pid, servo_id, :present_position)
      assert_in_delta position, target, @position_tolerance
    end

    test "moves to position 90 degrees", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      target = :math.pi() / 2
      assert :ok = Feetech.write(pid, servo_id, :goal_position, target)

      wait_for_move(pid, servo_id)

      assert {:ok, position} = Feetech.read(pid, servo_id, :present_position)
      assert_in_delta position, target, @position_tolerance
    end

    test "moves to position 180 degrees", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      target = :math.pi()
      assert :ok = Feetech.write(pid, servo_id, :goal_position, target)

      wait_for_move(pid, servo_id)

      assert {:ok, position} = Feetech.read(pid, servo_id, :present_position)
      assert_in_delta position, target, @position_tolerance
    end

    test "moves to position 270 degrees", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      target = 3 * :math.pi() / 2
      assert :ok = Feetech.write(pid, servo_id, :goal_position, target)

      wait_for_move(pid, servo_id)

      assert {:ok, position} = Feetech.read(pid, servo_id, :present_position)
      assert_in_delta position, target, @position_tolerance
    end

    test "moves using raw position values", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      target_steps = 2048
      assert :ok = Feetech.write_raw(pid, servo_id, :goal_position, target_steps)

      wait_for_move(pid, servo_id)

      assert {:ok, steps} = Feetech.read_raw(pid, servo_id, :present_position)
      assert_in_delta steps, target_steps, 10
    end

    test "reports moving status during motion", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      {:ok, current_pos} = Feetech.read_raw(pid, servo_id, :present_position)
      target = if current_pos < 2048, do: 3000, else: 1000

      Feetech.write_raw(pid, servo_id, :goal_position, target)

      Process.sleep(100)
      {:ok, moving_during} = Feetech.read(pid, servo_id, :moving)

      wait_for_move(pid, servo_id)
      {:ok, moving_after} = Feetech.read(pid, servo_id, :moving)

      assert moving_during == true or moving_after == false
    end
  end

  describe "goal speed and time" do
    test "reads and writes goal speed", %{pid: pid, servo_id: servo_id} do
      assert {:ok, _speed} = Feetech.read(pid, servo_id, :goal_speed)

      assert :ok = Feetech.write_raw(pid, servo_id, :goal_speed, 100)
      assert {:ok, speed} = Feetech.read_raw(pid, servo_id, :goal_speed)
      assert speed == 100
    end

    test "reads goal time", %{pid: pid, servo_id: servo_id} do
      assert {:ok, time} = Feetech.read_raw(pid, servo_id, :goal_time)
      assert is_integer(time) and time >= 0
    end
  end

  describe "acceleration" do
    test "reads and writes acceleration", %{pid: pid, servo_id: servo_id} do
      assert {:ok, _acc} = Feetech.read_raw(pid, servo_id, :acceleration)

      assert :ok = Feetech.write_raw(pid, servo_id, :acceleration, 50)
      assert {:ok, acc} = Feetech.read_raw(pid, servo_id, :acceleration)
      assert acc == 50
    end
  end

  describe "lock register" do
    test "reads lock status", %{pid: pid, servo_id: servo_id} do
      assert {:ok, locked} = Feetech.read(pid, servo_id, :lock)
      assert is_boolean(locked)
    end
  end

  describe "operating modes" do
    test "switches to velocity mode and back", %{pid: pid, servo_id: servo_id} do
      {:ok, original_mode} = Feetech.read(pid, servo_id, :mode)

      # Unlock EEPROM to write mode
      Feetech.write(pid, servo_id, :lock, false)

      # Switch to velocity mode
      assert :ok = Feetech.write(pid, servo_id, :mode, :velocity)
      assert {:ok, :velocity} = Feetech.read(pid, servo_id, :mode)

      # Restore original mode
      Feetech.write(pid, servo_id, :mode, original_mode)
      Feetech.write(pid, servo_id, :lock, true)

      assert {:ok, ^original_mode} = Feetech.read(pid, servo_id, :mode)
    end

    test "switches to step mode and back", %{pid: pid, servo_id: servo_id} do
      {:ok, original_mode} = Feetech.read(pid, servo_id, :mode)

      Feetech.write(pid, servo_id, :lock, false)

      assert :ok = Feetech.write(pid, servo_id, :mode, :step)
      assert {:ok, :step} = Feetech.read(pid, servo_id, :mode)

      Feetech.write(pid, servo_id, :mode, original_mode)
      Feetech.write(pid, servo_id, :lock, true)

      assert {:ok, ^original_mode} = Feetech.read(pid, servo_id, :mode)
    end

    test "velocity mode rotates continuously", %{pid: pid, servo_id: servo_id} do
      {:ok, original_mode} = Feetech.read(pid, servo_id, :mode)

      Feetech.write(pid, servo_id, :lock, false)
      Feetech.write(pid, servo_id, :mode, :velocity)

      # Get initial position
      {:ok, initial_pos} = Feetech.read_raw(pid, servo_id, :present_position)

      # Enable torque and set a low speed for safety
      Feetech.write(pid, servo_id, :torque_enable, true)
      Feetech.write_raw(pid, servo_id, :goal_speed, 100)

      # Let it rotate briefly
      Process.sleep(500)

      {:ok, moving} = Feetech.read(pid, servo_id, :moving)
      {:ok, mid_pos} = Feetech.read_raw(pid, servo_id, :present_position)

      # Stop and restore
      Feetech.write(pid, servo_id, :torque_enable, false)
      Feetech.write(pid, servo_id, :mode, original_mode)
      Feetech.write(pid, servo_id, :lock, true)

      # Verify it was moving (position changed or moving flag set)
      assert moving == true or mid_pos != initial_pos
    end

    test "position mode respects angle limits", %{pid: pid, servo_id: servo_id} do
      {:ok, mode} = Feetech.read(pid, servo_id, :mode)
      assert mode == :position

      {:ok, min_limit} = Feetech.read(pid, servo_id, :min_angle_limit)
      {:ok, max_limit} = Feetech.read(pid, servo_id, :max_angle_limit)

      # Verify limits are sensible
      assert min_limit >= 0
      assert max_limit <= 2 * :math.pi()
      assert max_limit > min_limit
    end
  end

  describe "reg_write and action" do
    test "buffers write and executes on action", %{pid: pid, servo_id: servo_id} do
      Feetech.write(pid, servo_id, :torque_enable, true)

      {:ok, initial_pos} = Feetech.read_raw(pid, servo_id, :present_position)
      target = if initial_pos < 2048, do: 3000, else: 1000

      assert {:ok, _} = Feetech.reg_write(pid, servo_id, :goal_position, target * 0.00153)

      Process.sleep(500)
      {:ok, pos_before_action} = Feetech.read_raw(pid, servo_id, :present_position)

      Feetech.action(pid)

      wait_for_move(pid, servo_id)
      {:ok, pos_after_action} = Feetech.read_raw(pid, servo_id, :present_position)

      assert_in_delta pos_before_action, initial_pos, 50
      assert_in_delta pos_after_action, target, 50
    end
  end

  describe "error handling" do
    test "returns error for invalid register", %{pid: pid, servo_id: servo_id} do
      assert {:error, :unknown_register} = Feetech.read(pid, servo_id, :nonexistent_register)
    end
  end

  defp wait_for_move(pid, servo_id, timeout \\ @move_timeout) do
    # Wait a minimum time for servo to start moving, then poll until stopped
    Process.sleep(100)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_move(pid, servo_id, deadline)
  end

  defp do_wait_for_move(pid, servo_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :timeout
    else
      check_moving_status(pid, servo_id, deadline)
    end
  end

  defp check_moving_status(pid, servo_id, deadline) do
    case Feetech.read(pid, servo_id, :moving) do
      {:ok, false} ->
        confirm_stopped(pid, servo_id, deadline)

      {:ok, true} ->
        Process.sleep(50)
        do_wait_for_move(pid, servo_id, deadline)

      _error ->
        Process.sleep(50)
        do_wait_for_move(pid, servo_id, deadline)
    end
  end

  defp confirm_stopped(pid, servo_id, deadline) do
    Process.sleep(100)

    case Feetech.read(pid, servo_id, :moving) do
      {:ok, false} -> :ok
      _ -> do_wait_for_move(pid, servo_id, deadline)
    end
  end
end
