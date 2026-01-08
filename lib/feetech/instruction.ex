# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Feetech.Instruction do
  @moduledoc """
  Instruction codes for the Feetech servo protocol.

  These are the command bytes sent in instruction packets to control servo behaviour.
  """

  @typedoc "Instruction code byte"
  @type t :: non_neg_integer()

  @doc "Query servo status"
  defmacro ping, do: 0x01

  @doc "Read data from control table"
  defmacro read, do: 0x02

  @doc "Write data to control table"
  defmacro write, do: 0x03

  @doc "Buffered write - waits for action command"
  defmacro reg_write, do: 0x04

  @doc "Execute all buffered reg_write commands"
  defmacro action, do: 0x05

  @doc "Reset control table to factory defaults"
  defmacro recovery, do: 0x06

  @doc "Reset servo state (rotation count)"
  defmacro reset, do: 0x0A

  @doc "Read from multiple servos simultaneously"
  defmacro sync_read, do: 0x82

  @doc "Write to multiple servos simultaneously"
  defmacro sync_write, do: 0x83

  @doc "Broadcast ID - all servos receive but don't respond"
  defmacro broadcast_id, do: 0xFE
end
