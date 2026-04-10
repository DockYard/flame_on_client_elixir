defmodule FlameOn.Client.Capture.Block do
  @moduledoc """
  DEPRECATED: Block struct is no longer used by TraceSession (Phase 3).

  TraceSession now builds streaming collapsed stacks incrementally using
  a lightweight call_stack (list of MFA tuples) instead of a Block tree.
  This module is retained for backward compatibility with existing tests
  but should not be used in new code.
  """

  defstruct id: nil,
            children: [],
            duration: nil,
            function: nil,
            level: nil,
            absolute_start: nil,
            max_child_level: nil
end
