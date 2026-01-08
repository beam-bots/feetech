# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.ControlTable do
  @moduledoc """
  Behaviour for servo-specific control table definitions.

  Each servo model has a different memory layout (control table) that defines
  the addresses, sizes, and conversions for readable/writable parameters.

  ## Implementing a Control Table

      defmodule MyServo do
        @behaviour Feetech.ControlTable

        @impl true
        def model_name, do: "MyServo"

        @impl true
        def registers do
          %{
            id: {5, 1, nil},
            goal_position: {42, 2, :position},
            present_position: {56, 2, :position}
          }
        end
      end

  ## Conversion Types

  The third element of each register tuple specifies how to convert between
  raw register values and user-friendly values:

    * `nil` - No conversion, raw integer value
    * `:bool` - 0/1 to false/true
    * `float` - Scale factor (e.g., `0.1` for voltage in 0.1V units)
    * `:position` - Steps to radians (servo-specific)
    * `:speed` - Speed units to rad/s
    * `:speed_signed` - Signed speed to rad/s
    * `:load_signed` - Signed load percentage
    * `:mode` - Operating mode enum
    * `:baud_rate` - Baud rate enum
    * `{module, decode_fun, encode_fun}` - Custom conversion functions
  """

  alias Feetech.Protocol

  @typedoc "Register name atom"
  @type register_name :: atom()

  @typedoc "Memory address in control table"
  @type address :: non_neg_integer()

  @typedoc "Number of bytes for register"
  @type byte_length :: 1 | 2 | 4

  @typedoc """
  Conversion specification for translating between raw and user values.
  """
  @type conversion ::
          nil
          | :bool
          | :position
          | :speed
          | :speed_signed
          | :load_signed
          | :mode
          | :baud_rate
          | float()
          | {module(), atom(), atom()}

  @typedoc "Register definition tuple"
  @type register_def :: {address(), byte_length(), conversion()}

  @typedoc "Map of register names to their definitions"
  @type registers :: %{register_name() => register_def()}

  @doc "Returns the human-readable model name"
  @callback model_name() :: String.t()

  @doc "Returns the register definitions map"
  @callback registers() :: registers()

  @doc """
  Looks up a register definition by name.
  """
  @spec get_register(module(), register_name()) ::
          {:ok, register_def()} | {:error, :unknown_register}
  def get_register(control_table, name) do
    case Map.fetch(control_table.registers(), name) do
      {:ok, def} -> {:ok, def}
      :error -> {:error, :unknown_register}
    end
  end

  @doc """
  Encodes a user value to raw bytes for writing to a register.
  """
  @spec encode(module(), register_name(), term()) :: {:ok, binary()} | {:error, atom()}
  def encode(control_table, name, value) do
    with {:ok, {_address, length, conversion}} <- get_register(control_table, name) do
      {:ok, encode_value(value, length, conversion, control_table)}
    end
  end

  @doc """
  Decodes raw bytes from a register to a user value.
  """
  @spec decode(module(), register_name(), binary()) :: {:ok, term()} | {:error, atom()}
  def decode(control_table, name, data) do
    with {:ok, {_address, _length, conversion}} <- get_register(control_table, name) do
      {:ok, decode_value(data, conversion, control_table)}
    end
  end

  @doc """
  Encodes a raw integer value to bytes (no conversion).
  """
  @spec encode_raw(module(), register_name(), integer()) :: {:ok, binary()} | {:error, atom()}
  def encode_raw(control_table, name, value) do
    with {:ok, {_address, length, _conversion}} <- get_register(control_table, name) do
      {:ok, Protocol.encode_int(value, length)}
    end
  end

  @doc """
  Decodes raw bytes to an integer (no conversion).
  """
  @spec decode_raw(binary()) :: integer()
  def decode_raw(data), do: Protocol.decode_int(data)

  defp encode_value(value, length, nil, _table) do
    Protocol.encode_int(round(value), length)
  end

  defp encode_value(value, length, :bool, _table) do
    Protocol.encode_int(if(value, do: 1, else: 0), length)
  end

  defp encode_value(value, length, scale, _table) when is_float(scale) do
    Protocol.encode_int(round(value / scale), length)
  end

  defp encode_value(value, length, :position, table) do
    steps = round(value / table.position_scale())
    Protocol.encode_int(steps, length)
  end

  defp encode_value(value, length, :speed, table) do
    raw = round(value / table.speed_scale())
    Protocol.encode_int(raw, length)
  end

  defp encode_value(value, length, :speed_signed, table) do
    raw = round(value / table.speed_scale())
    Protocol.encode_int(raw, length)
  end

  defp encode_value(value, length, :load_signed, _table) do
    raw = round(value * 10)
    Protocol.encode_int(raw, length)
  end

  defp encode_value(value, length, :mode, table) do
    raw = table.mode_to_raw(value)
    Protocol.encode_int(raw, length)
  end

  defp encode_value(value, length, :baud_rate, table) do
    raw = table.baud_rate_to_raw(value)
    Protocol.encode_int(raw, length)
  end

  defp encode_value(value, length, {module, _decode_fun, encode_fun}, _table) do
    raw = apply(module, encode_fun, [value])
    Protocol.encode_int(raw, length)
  end

  defp decode_value(data, nil, _table) do
    Protocol.decode_int(data)
  end

  defp decode_value(data, :bool, _table) do
    Protocol.decode_int(data) != 0
  end

  defp decode_value(data, scale, _table) when is_float(scale) do
    Protocol.decode_int(data) * scale
  end

  defp decode_value(data, :position, table) do
    Protocol.decode_int(data) * table.position_scale()
  end

  defp decode_value(data, :speed, table) do
    Protocol.decode_int(data) * table.speed_scale()
  end

  defp decode_value(data, :speed_signed, table) do
    Protocol.decode_int_signed(data) * table.speed_scale()
  end

  defp decode_value(data, :load_signed, _table) do
    Protocol.decode_int_signed(data) * 0.1
  end

  defp decode_value(data, :mode, table) do
    table.raw_to_mode(Protocol.decode_int(data))
  end

  defp decode_value(data, :baud_rate, table) do
    table.raw_to_baud_rate(Protocol.decode_int(data))
  end

  defp decode_value(data, {module, decode_fun, _encode_fun}, _table) do
    apply(module, decode_fun, [Protocol.decode_int(data)])
  end
end
