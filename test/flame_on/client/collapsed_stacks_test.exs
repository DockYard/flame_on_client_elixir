defmodule FlameOn.Client.CollapsedStacksTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.Capture.Stack
  alias FlameOn.Client.CollapsedStacks
  alias FlameOn.Client.Fixtures

  describe "convert/1" do
    test "converts a single leaf block into one collapsed stack entry" do
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :foo, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1300}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      assert [
               %{stack_path: "example.root/0;example.foo/0", duration_us: 200}
             ] = result
    end

    test "converts multiple children into separate collapsed stack entries" do
      # root: 1100-1500 = 400us, child1: 100us, child2: 200us, gap: 100us self-time
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :child1, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1200},
          {:call, {:example, :child2, 0}, 1300},
          {:return_to, {:example, :root, 0}, 1500}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # 3 entries: root self-time (gap between children) + 2 children
      assert length(result) == 3

      child1 = Enum.find(result, &(&1.stack_path == "example.root/0;example.child1/0"))
      assert child1.duration_us == 100

      child2 = Enum.find(result, &(&1.stack_path == "example.root/0;example.child2/0"))
      assert child2.duration_us == 200

      self_entry = Enum.find(result, &(&1.stack_path == "example.root/0"))
      assert self_entry.duration_us == 100
    end

    test "converts deeply nested blocks into full paths" do
      # mid: 400us total, leaf: 200us, mid self-time: 200us
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :mid, 0}, 1100},
          {:call, {:example, :leaf, 0}, 1200},
          {:return_to, {:example, :mid, 0}, 1400},
          {:return_to, {:example, :root, 0}, 1500}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      assert length(result) == 2

      leaf_entry =
        Enum.find(result, &(&1.stack_path == "example.root/0;example.mid/0;example.leaf/0"))

      assert leaf_entry.duration_us == 200

      mid_self = Enum.find(result, &(&1.stack_path == "example.root/0;example.mid/0"))
      assert mid_self.duration_us == 200
    end

    test "includes self-time for non-leaf nodes with children that don't account for all time" do
      # root: absolute_start=1100, duration=400 (from 1100 to 1500)
      # child1: 1100-1200 = 100us, child2: 1400-1500 = 100us
      # root self-time: 400 - 200 = 200us (gap between children)
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :child1, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1200},
          {:call, {:example, :child2, 0}, 1400},
          {:return_to, {:example, :root, 0}, 1500}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      child1_entry = Enum.find(result, &(&1.stack_path == "example.root/0;example.child1/0"))
      assert child1_entry.duration_us == 100

      child2_entry = Enum.find(result, &(&1.stack_path == "example.root/0;example.child2/0"))
      assert child2_entry.duration_us == 100

      self_entry = Enum.find(result, &(&1.stack_path == "example.root/0"))
      assert self_entry.duration_us == 200
    end

    test "does not emit self-time entry when children account for all time" do
      # root: 1100-1300 = 200us total
      # child1: 1100-1200 = 100us
      # child2: 1200-1300 = 100us
      # root self-time: 200 - 200 = 0us → no self-time entry
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :child1, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1200},
          {:call, {:example, :child2, 0}, 1200},
          {:return_to, {:example, :root, 0}, 1300}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # Should only have leaf entries, no self-time for root
      assert length(result) == 2
      paths = Enum.map(result, & &1.stack_path)
      refute "example.root/0" in paths
    end

    test "formats erlang module functions correctly" do
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:lists, :reverse, 1}, 1100},
          {:return_to, {:example, :root, 0}, 1300}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      assert [%{stack_path: "example.root/0;lists.reverse/1"}] = result
    end

    test "includes sleep blocks as children in collapsed stacks" do
      # Build a stack where foo has a sleep child, then finalize
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :wrapper, 0}, 900},
          {:call, {:example, :foo, 0}, 1000},
          {:call, :sleep, 1100},
          {:return_to, :sleep, 1200},
          {:return_to, {:example, :foo, 0}, 1300}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # SLEEP should appear as a child of foo
      sleep_entry = Enum.find(result, fn e -> String.contains?(e.stack_path, "SLEEP") end)
      assert sleep_entry.stack_path == "example.wrapper/0;example.foo/0;SLEEP"
      assert sleep_entry.duration_us == 100

      # foo's self-time should NOT absorb the sleep duration
      foo_entry = Enum.find(result, &(&1.stack_path == "example.wrapper/0;example.foo/0"))
      assert foo_entry.duration_us == 200
    end

    test "includes timer.sleep/1 function calls in collapsed stacks" do
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :work, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1200},
          {:call, {:timer, :sleep, 1}, 1200},
          {:return_to, {:example, :root, 0}, 1500}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # timer.sleep should appear as a child of root
      sleep_entry = Enum.find(result, &String.contains?(&1.stack_path, "timer.sleep"))
      assert sleep_entry.stack_path == "example.root/0;timer.sleep/1"
      assert sleep_entry.duration_us == 300

      # work should be present
      assert Enum.find(result, &(&1.stack_path == "example.root/0;example.work/0"))

      # root should have no self-time (children account for all time)
      root_self = Enum.find(result, &(&1.stack_path == "example.root/0"))
      refute root_self
    end

    test "includes sleep blocks that are direct children of root" do
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :root, 0}, 1000},
          {:call, {:example, :work1, 0}, 1100},
          {:return_to, {:example, :root, 0}, 1200},
          {:call, :sleep, 1200},
          {:return_to, :sleep, 1500},
          {:call, {:example, :work2, 0}, 1500},
          {:return_to, {:example, :root, 0}, 1600}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # SLEEP should appear as a child of root
      sleep_entry = Enum.find(result, &String.contains?(&1.stack_path, "SLEEP"))
      assert sleep_entry.stack_path == "example.root/0;SLEEP"
      assert sleep_entry.duration_us == 300

      # work1 and work2 should be present
      assert Enum.find(result, &(&1.stack_path == "example.root/0;example.work1/0"))
      assert Enum.find(result, &(&1.stack_path == "example.root/0;example.work2/0"))
    end

    test "handles zero duration leaf blocks" do
      stack =
        Fixtures.build_stack_from_trace_events([
          {:call, {:example, :parent, 0}, 1000},
          {:call, {:example, :child, 0}, 1000},
          {:return_to, {:example, :parent, 0}, 1000}
        ])

      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      # Zero duration leaves should still be included
      assert [%{stack_path: "example.parent/0;example.child/0", duration_us: 0}] = result
    end

    test "handles complex tree with mixed depths" do
      events = [
        {:call, {:example, :root, 0}, 1000},
        {:call, {:example, :child1, 0}, 1100},
        {:call, {:example, :grandchild, 0}, 1150},
        {:return_to, {:example, :child1, 0}, 1200},
        {:return_to, {:example, :root, 0}, 1250},
        {:call, {:example, :child2, 0}, 1300},
        {:return_to, {:example, :root, 0}, 1450}
      ]

      stack = Fixtures.build_stack_from_trace_events(events)
      [root] = Stack.finalize_stack(stack)
      result = CollapsedStacks.convert(root)

      paths = Enum.map(result, & &1.stack_path) |> Enum.sort()

      assert "example.root/0;example.child1/0;example.grandchild/0" in paths
      assert "example.root/0;example.child2/0" in paths
    end
  end

  describe "format_function/1" do
    test "formats MFA tuple" do
      assert CollapsedStacks.format_function({MyApp.Orders, :list_orders, 1}) ==
               "Elixir.MyApp.Orders.list_orders/1"
    end

    test "formats atom module MFA" do
      assert CollapsedStacks.format_function({:timer, :sleep, 1}) == "timer.sleep/1"
    end

    test "formats sleep atom" do
      assert CollapsedStacks.format_function(:sleep) == "SLEEP"
    end

    test "formats root tuple" do
      assert CollapsedStacks.format_function({:root, "phoenix.request", "GET /users/:id"}) ==
               "phoenix.request GET /users/:id"
    end

    test "formats cross-process call with registered name" do
      assert CollapsedStacks.format_function({:cross_process_call, self(), MyApp.Repo}) ==
               "CALL MyApp.Repo"
    end

    test "formats cross-process call without registered name" do
      assert CollapsedStacks.format_function({:cross_process_call, self(), nil}) ==
               "CALL <process>"
    end

    test "formats cross-process call with message form" do
      assert CollapsedStacks.format_function(
               {:cross_process_call, self(), MyApp.Repo, {:get, :user, 42}}
             ) ==
               "CALL MyApp.Repo {:get, :user, 42}"
    end

    test "formats cross-process call with sanitized message" do
      assert CollapsedStacks.format_function(
               {:cross_process_call, self(), MyApp.Worker, {:update, "%{...}", "..."}}
             ) ==
               ~s(CALL MyApp.Worker {:update, "%{...}", "..."})
    end
  end
end
