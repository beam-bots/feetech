# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.ErrorTest do
  use ExUnit.Case, async: true

  alias Feetech.Error

  describe "parse_status/1" do
    test "returns empty errors for status 0" do
      result = Error.parse_status(0x00)
      assert result.errors == []
      assert result.torque_enabled == false
    end

    test "detects torque enabled flag" do
      result = Error.parse_status(0x10)
      assert result.errors == []
      assert result.torque_enabled == true
    end

    test "detects voltage error" do
      result = Error.parse_status(0x01)
      assert :voltage_error in result.errors
    end

    test "detects sensor error" do
      result = Error.parse_status(0x02)
      assert :sensor_error in result.errors
    end

    test "detects temperature error" do
      result = Error.parse_status(0x04)
      assert :temperature_error in result.errors
    end

    test "detects current error" do
      result = Error.parse_status(0x08)
      assert :current_error in result.errors
    end

    test "detects overload error" do
      result = Error.parse_status(0x20)
      assert :overload_error in result.errors
    end

    test "detects multiple errors" do
      # Voltage + temperature + overload
      result = Error.parse_status(0x25)
      assert :voltage_error in result.errors
      assert :temperature_error in result.errors
      assert :overload_error in result.errors
      assert length(result.errors) == 3
    end

    test "torque flag is separate from errors" do
      # Torque enabled + voltage error
      result = Error.parse_status(0x11)
      assert :voltage_error in result.errors
      assert result.torque_enabled == true
    end
  end

  describe "error?/1" do
    test "returns false for no errors" do
      refute Error.error?(0x00)
      refute Error.error?(0x10)
    end

    test "returns true for any error" do
      assert Error.error?(0x01)
      assert Error.error?(0x02)
      assert Error.error?(0x04)
      assert Error.error?(0x08)
      assert Error.error?(0x20)
    end

    test "returns true for multiple errors" do
      assert Error.error?(0x25)
    end
  end

  describe "describe/1" do
    test "returns descriptions for all error types" do
      assert Error.describe(:voltage_error) =~ "Voltage"
      assert Error.describe(:sensor_error) =~ "encoder"
      assert Error.describe(:temperature_error) =~ "temperature"
      assert Error.describe(:current_error) =~ "current"
      assert Error.describe(:overload_error) =~ "Overload"
      assert Error.describe(:no_response) =~ "response"
      assert Error.describe(:invalid_checksum) =~ "checksum"
      assert Error.describe(:timeout) =~ "timeout"
    end

    test "handles unknown errors" do
      result = Error.describe(:unknown_thing)
      assert is_binary(result)
    end
  end
end
