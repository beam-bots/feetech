# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.SyncWriteSpanTest do
  use ExUnit.Case, async: true

  alias Feetech.ControlTable
  alias Feetech.ControlTable.STS3215

  doctest Feetech.ControlTable, only: [contiguous_span: 2]

  describe "contiguous_span/2" do
    test "a single register spans its own length" do
      assert {:ok, {42, 2}} = ControlTable.contiguous_span(STS3215, [:goal_position])
    end

    test "adjacent registers combine into one span" do
      # goal_position 42..43, goal_time 44..45, goal_speed 46..47
      assert {:ok, {42, 6}} =
               ControlTable.contiguous_span(STS3215, [:goal_position, :goal_time, :goal_speed])
    end

    test "a gap is refused, naming the pair that does not meet" do
      assert {:error, {:not_contiguous, :goal_position, :goal_speed}} =
               ControlTable.contiguous_span(STS3215, [:goal_position, :goal_speed])
    end

    test "descending order is refused" do
      assert {:error, {:not_contiguous, :goal_speed, :goal_position}} =
               ControlTable.contiguous_span(STS3215, [:goal_speed, :goal_position])
    end

    test "an unknown register is named" do
      assert {:error, {:unknown_register, :nonsense}} =
               ControlTable.contiguous_span(STS3215, [:goal_position, :nonsense])
    end

    test "an empty list has no span" do
      assert {:error, :no_registers} = ControlTable.contiguous_span(STS3215, [])
    end

    test "spans that run to the end of a block still work" do
      assert {:ok, {40, 8}} =
               ControlTable.contiguous_span(STS3215, [
                 :torque_enable,
                 :acceleration,
                 :goal_position,
                 :goal_time,
                 :goal_speed
               ])
    end
  end

  describe "the span a position move needs" do
    test "position, time and speed are adjacent, in that order" do
      registers = [:goal_position, :goal_time, :goal_speed]
      assert {:ok, {address, length}} = ControlTable.contiguous_span(STS3215, registers)

      # one instruction carrying all three is what stops the servo starting a
      # move before its speed has landed
      assert address == 42
      assert length == 6
    end

    test "the three encode to six bytes in address order" do
      encoded =
        [{:goal_position, 2048}, {:goal_time, 0}, {:goal_speed, 196}]
        |> Enum.map(fn {register, value} ->
          {:ok, bytes} = ControlTable.encode_raw(STS3215, register, value)
          bytes
        end)
        |> IO.iodata_to_binary()

      assert byte_size(encoded) == 6
      assert <<0x00, 0x08, 0x00, 0x00, 0xC4, 0x00>> = encoded
    end
  end
end
