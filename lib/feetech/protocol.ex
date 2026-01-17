# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.Protocol do
  @moduledoc """
  Packet encoding and decoding for the Feetech servo protocol.

  ## Packet Format

  **Instruction packet (controller to servo):**
  ```
  Header | ID | Length | Instruction | Params | Checksum
  0xFF 0xFF | 1 byte | 1 byte | 1 byte | N bytes | 1 byte
  ```

  **Response packet (servo to controller):**
  ```
  Header | ID | Length | Status | Params | Checksum
  0xFF 0xFF | 1 byte | 1 byte | 1 byte | N bytes | 1 byte
  ```

  Length = number of parameters + 2 (for instruction/status + checksum)
  Checksum = ~(ID + Length + Instruction + Params) & 0xFF
  """

  import Bitwise

  require Feetech.Instruction
  alias Feetech.Instruction

  @header <<0xFF, 0xFF>>

  @typedoc "Servo ID (0-253, or 254 for broadcast)"
  @type servo_id :: 0..254

  @typedoc "Memory address in control table"
  @type address :: non_neg_integer()

  @typedoc "Parsed response from servo"
  @type response :: %{
          id: servo_id(),
          status: non_neg_integer(),
          params: binary()
        }

  @doc """
  Calculates the checksum for packet data.

  The checksum is the bitwise NOT of the sum of all bytes, masked to 8 bits.

  ## Examples

      iex> Feetech.Protocol.checksum(<<1, 2, 1>>)
      0xFB
  """
  @spec checksum(binary()) :: byte()
  def checksum(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.sum()
    |> Bitwise.band(0xFF)
    |> Bitwise.bxor(0xFF)
  end

  @doc """
  Validates a packet's checksum.
  """
  @spec valid_checksum?(binary(), byte()) :: boolean()
  def valid_checksum?(data, expected_checksum) do
    checksum(data) == expected_checksum
  end

  @doc """
  Builds a PING instruction packet.

  PING queries the servo's status and returns a response even with broadcast ID.

  ## Examples

      iex> Feetech.Protocol.build_ping(1)
      <<0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB>>
  """
  @spec build_ping(servo_id()) :: binary()
  def build_ping(id) do
    build_packet(id, Instruction.ping(), <<>>)
  end

  @doc """
  Builds a READ instruction packet.

  ## Examples

      iex> Feetech.Protocol.build_read(1, 56, 2)
      <<0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x02, 0xBE>>
  """
  @spec build_read(servo_id(), address(), pos_integer()) :: binary()
  def build_read(id, address, length) do
    build_packet(id, Instruction.read(), <<address, length>>)
  end

  @doc """
  Builds a WRITE instruction packet.

  ## Examples

      iex> Feetech.Protocol.build_write(1, 42, <<0x00, 0x08>>)
      <<0xFF, 0xFF, 0x01, 0x05, 0x03, 0x2A, 0x00, 0x08, 0xC4>>
  """
  @spec build_write(servo_id(), address(), binary()) :: binary()
  def build_write(id, address, data) when is_binary(data) do
    build_packet(id, Instruction.write(), <<address>> <> data)
  end

  @doc """
  Builds a REG_WRITE instruction packet.

  Like WRITE, but the servo buffers the command until an ACTION is received.
  """
  @spec build_reg_write(servo_id(), address(), binary()) :: binary()
  def build_reg_write(id, address, data) when is_binary(data) do
    build_packet(id, Instruction.reg_write(), <<address>> <> data)
  end

  @doc """
  Builds an ACTION instruction packet.

  Triggers all buffered REG_WRITE commands. Typically sent to broadcast ID.
  """
  @spec build_action(servo_id()) :: binary()
  def build_action(id \\ Instruction.broadcast_id()) do
    build_packet(id, Instruction.action(), <<>>)
  end

  @doc """
  Builds a RECOVERY instruction packet (factory reset).
  """
  @spec build_recovery(servo_id()) :: binary()
  def build_recovery(id) do
    build_packet(id, Instruction.recovery(), <<>>)
  end

  @doc """
  Builds a RESET instruction packet (reset rotation count).
  """
  @spec build_reset(servo_id()) :: binary()
  def build_reset(id) do
    build_packet(id, Instruction.reset(), <<>>)
  end

  @doc """
  Builds a SYNC_WRITE instruction packet.

  Writes the same register(s) to multiple servos in a single packet.

  ## Parameters

    * `address` - Starting address in control table
    * `data_length` - Number of bytes per servo
    * `servo_data` - List of `{servo_id, data_binary}` tuples

  ## Examples

      iex> Feetech.Protocol.build_sync_write(42, 2, [{1, <<0x00, 0x08>>}, {2, <<0x00, 0x04>>}])
      # Writes position 2048 to servo 1, position 1024 to servo 2
  """
  @spec build_sync_write(address(), pos_integer(), [{servo_id(), binary()}]) :: binary()
  def build_sync_write(address, data_length, servo_data) when is_list(servo_data) do
    params =
      <<address, data_length>> <>
        Enum.reduce(servo_data, <<>>, fn {id, data}, acc ->
          acc <> <<id>> <> data
        end)

    build_packet(Instruction.broadcast_id(), Instruction.sync_write(), params)
  end

  @doc """
  Builds a SYNC_READ instruction packet.

  Reads the same register(s) from multiple servos. Responses are returned
  in the order of the ID list.

  ## Parameters

    * `address` - Starting address in control table
    * `length` - Number of bytes to read from each servo
    * `ids` - List of servo IDs to read from
  """
  @spec build_sync_read(address(), pos_integer(), [servo_id()]) :: binary()
  def build_sync_read(address, length, ids) when is_list(ids) do
    params = <<address, length>> <> :erlang.list_to_binary(ids)
    build_packet(Instruction.broadcast_id(), Instruction.sync_read(), params)
  end

  @doc """
  Parses a response packet from a servo.

  Returns `{:ok, response}` with the parsed ID, status, and parameters,
  or `{:error, reason}` if the packet is invalid.
  """
  @spec parse_response(binary()) :: {:ok, response()} | {:error, atom()}
  def parse_response(<<0xFF, 0xFF, id, length, status, rest::binary>>) do
    param_length = length - 2

    case rest do
      <<params::binary-size(param_length), packet_checksum>> ->
        body = <<id, length, status>> <> params

        if valid_checksum?(body, packet_checksum) do
          {:ok, %{id: id, status: status, params: params}}
        else
          {:error, :invalid_checksum}
        end

      _ ->
        {:error, :incomplete_packet}
    end
  end

  def parse_response(<<0xFF, 0xFF, _rest::binary>>) do
    {:error, :incomplete_packet}
  end

  def parse_response(_) do
    {:error, :invalid_header}
  end

  @doc """
  Attempts to extract a complete packet from a binary buffer.

  Returns `{:ok, packet, remaining}` if a complete packet is found,
  or `{:incomplete, buffer}` if more data is needed.
  """
  @spec extract_packet(binary()) ::
          {:ok, binary(), binary()}
          | {:incomplete, binary()}
  def extract_packet(<<0xFF, 0xFF, _id, length, _rest::binary>> = buffer) do
    packet_length = length + 4

    if byte_size(buffer) >= packet_length do
      <<packet::binary-size(packet_length), remaining::binary>> = buffer
      {:ok, packet, remaining}
    else
      {:incomplete, buffer}
    end
  end

  def extract_packet(<<0xFF, _>> = buffer), do: {:incomplete, buffer}
  def extract_packet(<<0xFF>>), do: {:incomplete, <<0xFF>>}
  def extract_packet(<<>>), do: {:incomplete, <<>>}

  def extract_packet(<<byte, rest::binary>>) do
    if byte == 0xFF do
      extract_packet(<<0xFF, rest::binary>>)
    else
      extract_packet(rest)
    end
  end

  @doc """
  Encodes an integer as little-endian binary.

  ## Examples

      iex> Feetech.Protocol.encode_int(2048, 2)
      <<0x00, 0x08>>

      iex> Feetech.Protocol.encode_int(1000, 2)
      <<0xE8, 0x03>>
  """
  @spec encode_int(integer(), 1 | 2 | 4) :: binary()
  def encode_int(value, 1), do: <<value &&& 0xFF>>
  def encode_int(value, 2), do: <<value &&& 0xFF, value >>> 8 &&& 0xFF>>

  def encode_int(value, 4) do
    <<
      value &&& 0xFF,
      value >>> 8 &&& 0xFF,
      value >>> 16 &&& 0xFF,
      value >>> 24 &&& 0xFF
    >>
  end

  @doc """
  Decodes a little-endian binary to an unsigned integer.

  ## Examples

      iex> Feetech.Protocol.decode_int(<<0x00, 0x08>>)
      2048

      iex> Feetech.Protocol.decode_int(<<0xE8, 0x03>>)
      1000
  """
  @spec decode_int(binary()) :: non_neg_integer()
  def decode_int(<<value>>), do: value
  def decode_int(<<low, high>>), do: high <<< 8 ||| low
  def decode_int(<<b0, b1, b2, b3>>), do: b3 <<< 24 ||| b2 <<< 16 ||| b1 <<< 8 ||| b0

  @doc """
  Decodes a little-endian binary to a signed integer (two's complement).

  ## Examples

      iex> Feetech.Protocol.decode_int_signed(<<0xFF, 0xFF>>)
      -1

      iex> Feetech.Protocol.decode_int_signed(<<0x00, 0x08>>)
      2048
  """
  @spec decode_int_signed(binary()) :: integer()
  def decode_int_signed(<<value>>) do
    if value > 127, do: value - 256, else: value
  end

  def decode_int_signed(<<_low, _high>> = data) do
    value = decode_int(data)
    if value > 32_767, do: value - 65_536, else: value
  end

  def decode_int_signed(<<_b0, _b1, _b2, _b3>> = data) do
    value = decode_int(data)
    if value > 2_147_483_647, do: value - 4_294_967_296, else: value
  end

  @doc """
  Encodes a signed integer using sign-magnitude encoding.

  The sign bit position determines where the sign is stored:
  - Bit 11 for homing_offset (range: -2047 to +2047)
  - Bit 15 for position values (range: -32767 to +32767)

  ## Examples

      iex> Feetech.Protocol.encode_sign_magnitude(-1000, 11, 2)
      <<0xE8, 0x0B>>

      iex> Feetech.Protocol.encode_sign_magnitude(1000, 11, 2)
      <<0xE8, 0x03>>
  """
  @spec encode_sign_magnitude(integer(), non_neg_integer(), 1 | 2) :: binary()
  def encode_sign_magnitude(value, sign_bit, length) do
    raw =
      if value < 0 do
        Bitwise.bor(1 <<< sign_bit, abs(value))
      else
        value
      end

    encode_int(raw, length)
  end

  @doc """
  Decodes a sign-magnitude encoded integer.

  The sign bit position determines where the sign is stored:
  - Bit 11 for homing_offset
  - Bit 15 for position values

  ## Examples

      iex> Feetech.Protocol.decode_sign_magnitude(<<0xE8, 0x0B>>, 11)
      -1000

      iex> Feetech.Protocol.decode_sign_magnitude(<<0xE8, 0x03>>, 11)
      1000
  """
  @spec decode_sign_magnitude(binary(), non_neg_integer()) :: integer()
  def decode_sign_magnitude(data, sign_bit) do
    raw = decode_int(data)
    sign_mask = 1 <<< sign_bit
    magnitude_mask = sign_mask - 1

    if Bitwise.band(raw, sign_mask) != 0 do
      -Bitwise.band(raw, magnitude_mask)
    else
      Bitwise.band(raw, magnitude_mask)
    end
  end

  defp build_packet(id, instruction, params) do
    length = byte_size(params) + 2
    body = <<id, length, instruction>> <> params
    packet_checksum = checksum(body)
    @header <> body <> <<packet_checksum>>
  end
end
