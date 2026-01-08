# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.ControlTable.STS3215 do
  @moduledoc """
  Control table for Feetech STS3215 and compatible STS series servos.

  These servos use a 12-bit magnetic encoder (4096 steps per revolution)
  and support position, velocity, and step control modes.

  ## Operating Modes

    * `:position` - Standard position control (default)
    * `:velocity` - Continuous rotation with speed control
    * `:step` - Stepper mode for multi-turn positioning

  ## Default Settings

    * Baud rate: 1,000,000 bps
    * ID: 1
    * Position range: 0-4095 (one full rotation)
  """

  @behaviour Feetech.ControlTable

  @steps_per_revolution 4096
  @position_scale 2 * :math.pi() / @steps_per_revolution
  @speed_unit 50
  @speed_scale @speed_unit * @position_scale

  @impl true
  def model_name, do: "STS3215"

  @doc """
  Radians per step for position conversion.

  4096 steps = 2π radians (one full revolution)
  """
  def position_scale, do: @position_scale

  @doc """
  Radians per second per speed unit.

  Speed unit = 50 steps/second
  """
  def speed_scale, do: @speed_scale

  @doc """
  Number of encoder steps per revolution.
  """
  def steps_per_revolution, do: @steps_per_revolution

  @impl true
  def registers do
    %{
      # EPROM - persisted settings (address 0-54)
      firmware_version_main: {0, 1, nil},
      firmware_version_sub: {1, 1, nil},
      servo_version_main: {3, 1, nil},
      servo_version_sub: {4, 1, nil},
      id: {5, 1, nil},
      baud_rate: {6, 1, :baud_rate},
      return_delay: {7, 1, nil},
      status_return_level: {8, 1, nil},
      min_angle_limit: {9, 2, :position},
      max_angle_limit: {11, 2, :position},
      max_temperature: {13, 1, nil},
      max_input_voltage: {14, 1, 0.1},
      min_input_voltage: {15, 1, 0.1},
      max_torque: {16, 2, 0.001},
      setting_byte: {18, 1, nil},
      protection_switch: {19, 1, nil},
      led_alarm_condition: {20, 1, nil},
      position_p_gain: {21, 1, nil},
      position_d_gain: {22, 1, nil},
      position_i_gain: {23, 1, nil},
      punch: {24, 1, nil},
      cw_dead_band: {26, 1, nil},
      ccw_dead_band: {27, 1, nil},
      overload_current: {28, 2, nil},
      angular_resolution: {30, 1, nil},
      position_offset: {31, 2, nil},
      mode: {33, 1, :mode},
      protection_torque: {34, 1, nil},
      protection_time: {35, 1, nil},
      overload_torque: {36, 1, nil},

      # SRAM - volatile settings (address 40-54)
      torque_enable: {40, 1, :bool},
      acceleration: {41, 1, nil},
      goal_position: {42, 2, :position},
      goal_time: {44, 2, nil},
      goal_speed: {46, 2, :speed},
      torque_limit: {48, 2, 0.001},
      lock: {55, 1, :bool},

      # SRAM - read-only feedback (address 56+)
      present_position: {56, 2, :position},
      present_speed: {58, 2, :speed_signed},
      present_load: {60, 2, :load_signed},
      present_voltage: {62, 1, 0.1},
      present_temperature: {63, 1, nil},
      async_write_status: {64, 1, nil},
      hardware_error_status: {65, 1, nil},
      moving: {66, 1, :bool},
      present_current: {69, 2, nil}
    }
  end

  @doc """
  Converts mode atom to raw register value.
  """
  def mode_to_raw(:position), do: 0
  def mode_to_raw(:velocity), do: 1
  def mode_to_raw(:pwm), do: 2
  def mode_to_raw(:step), do: 3

  @doc """
  Converts raw register value to mode atom.
  """
  def raw_to_mode(0), do: :position
  def raw_to_mode(1), do: :velocity
  def raw_to_mode(2), do: :pwm
  def raw_to_mode(3), do: :step
  def raw_to_mode(_), do: :unknown

  @baud_rates %{
    1_000_000 => 0,
    500_000 => 1,
    250_000 => 2,
    128_000 => 3,
    115_200 => 4,
    76_800 => 5,
    57_600 => 6,
    38_400 => 7
  }

  @raw_to_baud Map.new(@baud_rates, fn {k, v} -> {v, k} end)

  @doc """
  Converts baud rate to raw register value.
  """
  def baud_rate_to_raw(baud_rate), do: Map.get(@baud_rates, baud_rate, 0)

  @doc """
  Converts raw register value to baud rate.
  """
  def raw_to_baud_rate(raw), do: Map.get(@raw_to_baud, raw, 1_000_000)

  @doc """
  Returns the default baud rate for this servo series.
  """
  def default_baud_rate, do: 1_000_000
end
