# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.ProtocolTest do
  use ExUnit.Case, async: true

  alias Feetech.Protocol

  describe "checksum/1" do
    test "calculates checksum for ping packet body" do
      # ID=1, Length=2, Instruction=PING(0x01)
      body = <<0x01, 0x02, 0x01>>
      assert Protocol.checksum(body) == 0xFB
    end

    test "calculates checksum for read packet body" do
      # ID=1, Length=4, Instruction=READ(0x02), Address=0x38, Length=2
      body = <<0x01, 0x04, 0x02, 0x38, 0x02>>
      assert Protocol.checksum(body) == 0xBE
    end
  end

  describe "valid_checksum?/2" do
    test "returns true for valid checksum" do
      body = <<0x01, 0x02, 0x01>>
      assert Protocol.valid_checksum?(body, 0xFB)
    end

    test "returns false for invalid checksum" do
      body = <<0x01, 0x02, 0x01>>
      refute Protocol.valid_checksum?(body, 0x00)
    end
  end

  describe "build_ping/1" do
    test "builds correct ping packet" do
      # Example from protocol manual: FF FF 01 02 01 FB
      packet = Protocol.build_ping(1)
      assert packet == <<0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB>>
    end

    test "builds ping packet for different ID" do
      packet = Protocol.build_ping(5)
      # ID=5, Length=2, Instruction=0x01, Checksum=~(5+2+1)=0xF7
      assert packet == <<0xFF, 0xFF, 0x05, 0x02, 0x01, 0xF7>>
    end
  end

  describe "build_read/3" do
    test "builds correct read packet" do
      # Read present position (address 0x38, 2 bytes) from servo ID 1
      # Example from protocol manual: FF FF 01 04 02 38 02 BE
      packet = Protocol.build_read(1, 0x38, 2)
      assert packet == <<0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x02, 0xBE>>
    end
  end

  describe "build_write/3" do
    test "builds correct write packet for goal position" do
      # Write position 2048 (0x0800) to address 0x2A
      # Position: low=0x00, high=0x08
      packet = Protocol.build_write(1, 0x2A, <<0x00, 0x08>>)
      # ID=1, Length=5, Instruction=0x03, Addr=0x2A, Data=0x00,0x08
      # Checksum = ~(1+5+3+0x2A+0x00+0x08) = ~(0x3B) = 0xC4
      assert packet == <<0xFF, 0xFF, 0x01, 0x05, 0x03, 0x2A, 0x00, 0x08, 0xC4>>
    end
  end

  describe "build_sync_write/3" do
    test "builds correct sync write packet" do
      # Write position 2048 to servos 1-4 at address 0x2A with 6 bytes each
      # (position + time + speed)
      data = [
        {1, <<0x00, 0x08, 0x00, 0x00, 0xE8, 0x03>>},
        {2, <<0x00, 0x08, 0x00, 0x00, 0xE8, 0x03>>}
      ]

      packet = Protocol.build_sync_write(0x2A, 6, data)

      # Should start with header, broadcast ID (0xFE), and sync_write instruction (0x83)
      assert <<0xFF, 0xFF, 0xFE, _length, 0x83, 0x2A, 0x06, rest::binary>> = packet

      # First servo data: ID=1 followed by 6 bytes
      assert <<0x01, 0x00, 0x08, 0x00, 0x00, 0xE8, 0x03, _rest::binary>> = rest
    end
  end

  describe "build_action/0" do
    test "builds correct action packet" do
      packet = Protocol.build_action()
      # Broadcast ID (0xFE), Length=2, Instruction=0x05
      # Checksum = ~(0xFE+2+5) = ~(0x105) = ~(0x05) = 0xFA
      assert packet == <<0xFF, 0xFF, 0xFE, 0x02, 0x05, 0xFA>>
    end
  end

  describe "parse_response/1" do
    test "parses valid ping response" do
      # Response from protocol manual: FF FF 01 02 00 FC
      response = <<0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC>>
      assert {:ok, %{id: 1, status: 0, params: <<>>}} = Protocol.parse_response(response)
    end

    test "parses valid read response with data" do
      # Response with position data: FF FF 01 04 00 18 05 DD
      response = <<0xFF, 0xFF, 0x01, 0x04, 0x00, 0x18, 0x05, 0xDD>>

      assert {:ok, %{id: 1, status: 0, params: <<0x18, 0x05>>}} =
               Protocol.parse_response(response)
    end

    test "returns error for invalid checksum" do
      # Same as above but with wrong checksum
      response = <<0xFF, 0xFF, 0x01, 0x04, 0x00, 0x18, 0x05, 0x00>>
      assert {:error, :invalid_checksum} = Protocol.parse_response(response)
    end

    test "returns error for invalid header" do
      response = <<0x00, 0x00, 0x01, 0x02, 0x00, 0xFC>>
      assert {:error, :invalid_header} = Protocol.parse_response(response)
    end

    test "returns error for incomplete packet" do
      response = <<0xFF, 0xFF, 0x01, 0x04, 0x00>>
      assert {:error, :incomplete_packet} = Protocol.parse_response(response)
    end
  end

  describe "extract_packet/1" do
    test "extracts complete packet from buffer" do
      buffer = <<0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC, 0xAB, 0xCD>>

      assert {:ok, <<0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC>>, <<0xAB, 0xCD>>} =
               Protocol.extract_packet(buffer)
    end

    test "returns incomplete for partial packet" do
      buffer = <<0xFF, 0xFF, 0x01, 0x04, 0x00>>
      assert {:incomplete, ^buffer} = Protocol.extract_packet(buffer)
    end

    test "skips garbage bytes before header" do
      buffer = <<0x00, 0x00, 0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC>>
      assert {:ok, <<0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC>>, <<>>} = Protocol.extract_packet(buffer)
    end
  end

  describe "encode_int/2" do
    test "encodes 1-byte integer" do
      assert Protocol.encode_int(0x42, 1) == <<0x42>>
    end

    test "encodes 2-byte integer little-endian" do
      assert Protocol.encode_int(2048, 2) == <<0x00, 0x08>>
      assert Protocol.encode_int(1000, 2) == <<0xE8, 0x03>>
    end

    test "encodes 4-byte integer little-endian" do
      assert Protocol.encode_int(0x12345678, 4) == <<0x78, 0x56, 0x34, 0x12>>
    end
  end

  describe "decode_int/1" do
    test "decodes 1-byte integer" do
      assert Protocol.decode_int(<<0x42>>) == 0x42
    end

    test "decodes 2-byte integer little-endian" do
      assert Protocol.decode_int(<<0x00, 0x08>>) == 2048
      assert Protocol.decode_int(<<0xE8, 0x03>>) == 1000
    end

    test "decodes 4-byte integer little-endian" do
      assert Protocol.decode_int(<<0x78, 0x56, 0x34, 0x12>>) == 0x12345678
    end
  end

  describe "decode_int_signed/1" do
    test "decodes positive 2-byte signed integer" do
      assert Protocol.decode_int_signed(<<0x00, 0x08>>) == 2048
    end

    test "decodes negative 2-byte signed integer" do
      assert Protocol.decode_int_signed(<<0xFF, 0xFF>>) == -1
      assert Protocol.decode_int_signed(<<0x00, 0x80>>) == -32_768
    end

    test "decodes positive 1-byte signed integer" do
      assert Protocol.decode_int_signed(<<0x7F>>) == 127
    end

    test "decodes negative 1-byte signed integer" do
      assert Protocol.decode_int_signed(<<0xFF>>) == -1
      assert Protocol.decode_int_signed(<<0x80>>) == -128
    end
  end
end
