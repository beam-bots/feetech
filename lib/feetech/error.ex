# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.Error do
  @moduledoc """
  Error handling for Feetech servo responses.

  The status byte in response packets contains bit flags indicating
  various error conditions and the torque enable state.

  ## Status Byte Bits

  | Bit | Name | Description |
  |-----|------|-------------|
  | 0 | Voltage | Over/under voltage detected |
  | 1 | Sensor | Magnetic encoder error |
  | 2 | Temperature | Over temperature |
  | 3 | Current | Over current |
  | 4 | Torque | Torque is enabled (not an error) |
  | 5 | Overload | Overload protection triggered |
  """

  import Bitwise

  @type error ::
          :voltage_error
          | :sensor_error
          | :temperature_error
          | :current_error
          | :overload_error
          | :no_response
          | :invalid_checksum
          | :invalid_packet
          | :incomplete_packet
          | :invalid_header
          | :unknown_register
          | :timeout

  @type status_info :: %{
          errors: [error()],
          torque_enabled: boolean()
        }

  @voltage_error 0x01
  @sensor_error 0x02
  @temperature_error 0x04
  @current_error 0x08
  @torque_enabled 0x10
  @overload_error 0x20

  @doc """
  Parses a status byte into a structured result.

  Returns a map with detected errors and torque state.

  ## Examples

      iex> Feetech.Error.parse_status(0x00)
      %{errors: [], torque_enabled: false}

      iex> Feetech.Error.parse_status(0x10)
      %{errors: [], torque_enabled: true}

      iex> Feetech.Error.parse_status(0x25)
      %{errors: [:voltage_error, :temperature_error, :overload_error], torque_enabled: false}
  """
  @spec parse_status(non_neg_integer()) :: status_info()
  def parse_status(status) do
    errors =
      []
      |> maybe_add_error(status, @voltage_error, :voltage_error)
      |> maybe_add_error(status, @sensor_error, :sensor_error)
      |> maybe_add_error(status, @temperature_error, :temperature_error)
      |> maybe_add_error(status, @current_error, :current_error)
      |> maybe_add_error(status, @overload_error, :overload_error)
      |> Enum.reverse()

    %{
      errors: errors,
      torque_enabled: (status &&& @torque_enabled) != 0
    }
  end

  @doc """
  Returns true if the status byte indicates any error.
  """
  @spec error?(non_neg_integer()) :: boolean()
  def error?(status) do
    error_mask =
      @voltage_error ||| @sensor_error ||| @temperature_error ||| @current_error |||
        @overload_error

    (status &&& error_mask) != 0
  end

  @doc """
  Converts error atoms to human-readable descriptions.
  """
  @spec describe(error()) :: String.t()
  def describe(:voltage_error), do: "Voltage out of range"
  def describe(:sensor_error), do: "Magnetic encoder error"
  def describe(:temperature_error), do: "Over temperature"
  def describe(:current_error), do: "Over current"
  def describe(:overload_error), do: "Overload protection triggered"
  def describe(:no_response), do: "No response from servo"
  def describe(:invalid_checksum), do: "Invalid packet checksum"
  def describe(:invalid_packet), do: "Malformed packet"
  def describe(:incomplete_packet), do: "Incomplete packet received"
  def describe(:invalid_header), do: "Invalid packet header"
  def describe(:unknown_register), do: "Unknown register name"
  def describe(:timeout), do: "Communication timeout"
  def describe(other), do: "Unknown error: #{inspect(other)}"

  defp maybe_add_error(errors, status, mask, error) do
    if (status &&& mask) != 0 do
      [error | errors]
    else
      errors
    end
  end
end
