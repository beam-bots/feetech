# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.ControlTable.STS3215Test do
  use ExUnit.Case, async: true

  alias Feetech.ControlTable
  alias Feetech.ControlTable.STS3215

  describe "registers/0" do
    test "returns a map of register definitions" do
      registers = STS3215.registers()
      assert is_map(registers)
      assert map_size(registers) > 0
    end

    test "includes required registers" do
      registers = STS3215.registers()

      assert Map.has_key?(registers, :id)
      assert Map.has_key?(registers, :goal_position)
      assert Map.has_key?(registers, :present_position)
      assert Map.has_key?(registers, :torque_enable)
      assert Map.has_key?(registers, :mode)
    end

    test "registers have correct structure" do
      registers = STS3215.registers()

      {address, length, _conversion} = registers[:goal_position]
      assert address == 42
      assert length == 2
    end
  end

  describe "position conversion" do
    test "position_scale returns correct value" do
      # 4096 steps = 2π radians
      scale = STS3215.position_scale()
      assert_in_delta scale, 2 * :math.pi() / 4096, 1.0e-10
    end

    test "encodes radians to steps" do
      {:ok, data} = ControlTable.encode(STS3215, :goal_position, :math.pi())
      # π radians = 2048 steps
      assert data == <<0x00, 0x08>>
    end

    test "decodes steps to radians" do
      {:ok, value} = ControlTable.decode(STS3215, :present_position, <<0x00, 0x08>>)
      # 2048 steps = π radians
      assert_in_delta value, :math.pi(), 0.001
    end

    test "round-trip conversion preserves value" do
      original = 1.5
      {:ok, encoded} = ControlTable.encode(STS3215, :goal_position, original)
      {:ok, decoded} = ControlTable.decode(STS3215, :goal_position, encoded)
      # Should be within one step of original
      assert_in_delta decoded, original, STS3215.position_scale()
    end
  end

  describe "boolean conversion" do
    test "encodes true to 1" do
      {:ok, data} = ControlTable.encode(STS3215, :torque_enable, true)
      assert data == <<0x01>>
    end

    test "encodes false to 0" do
      {:ok, data} = ControlTable.encode(STS3215, :torque_enable, false)
      assert data == <<0x00>>
    end

    test "decodes 1 to true" do
      {:ok, value} = ControlTable.decode(STS3215, :torque_enable, <<0x01>>)
      assert value == true
    end

    test "decodes 0 to false" do
      {:ok, value} = ControlTable.decode(STS3215, :torque_enable, <<0x00>>)
      assert value == false
    end

    test "decodes non-zero to true" do
      {:ok, value} = ControlTable.decode(STS3215, :torque_enable, <<0xFF>>)
      assert value == true
    end
  end

  describe "mode conversion" do
    test "encodes :position mode" do
      {:ok, data} = ControlTable.encode(STS3215, :mode, :position)
      assert data == <<0x00>>
    end

    test "encodes :velocity mode" do
      {:ok, data} = ControlTable.encode(STS3215, :mode, :velocity)
      assert data == <<0x01>>
    end

    test "encodes :step mode" do
      {:ok, data} = ControlTable.encode(STS3215, :mode, :step)
      assert data == <<0x03>>
    end

    test "decodes mode values" do
      {:ok, value} = ControlTable.decode(STS3215, :mode, <<0x00>>)
      assert value == :position

      {:ok, value} = ControlTable.decode(STS3215, :mode, <<0x01>>)
      assert value == :velocity

      {:ok, value} = ControlTable.decode(STS3215, :mode, <<0x03>>)
      assert value == :step
    end
  end

  describe "baud rate conversion" do
    test "converts common baud rates" do
      assert STS3215.baud_rate_to_raw(1_000_000) == 0
      assert STS3215.baud_rate_to_raw(500_000) == 1
      assert STS3215.baud_rate_to_raw(115_200) == 4
    end

    test "converts raw to baud rate" do
      assert STS3215.raw_to_baud_rate(0) == 1_000_000
      assert STS3215.raw_to_baud_rate(1) == 500_000
      assert STS3215.raw_to_baud_rate(4) == 115_200
    end
  end

  describe "voltage conversion" do
    test "decodes voltage with 0.1V scale" do
      {:ok, value} = ControlTable.decode(STS3215, :present_voltage, <<0x4A>>)
      # 74 * 0.1 = 7.4V
      assert_in_delta value, 7.4, 0.01
    end
  end

  describe "raw encoding/decoding" do
    test "encode_raw returns raw integer as binary" do
      {:ok, data} = ControlTable.encode_raw(STS3215, :goal_position, 2048)
      assert data == <<0x00, 0x08>>
    end

    test "decode_raw returns raw integer" do
      value = ControlTable.decode_raw(<<0x00, 0x08>>)
      assert value == 2048
    end
  end

  describe "get_register/2" do
    test "returns register definition for known register" do
      {:ok, {address, length, conversion}} = ControlTable.get_register(STS3215, :goal_position)
      assert address == 42
      assert length == 2
      assert conversion == :position
    end

    test "returns error for unknown register" do
      assert {:error, :unknown_register} = ControlTable.get_register(STS3215, :nonexistent)
    end
  end
end
