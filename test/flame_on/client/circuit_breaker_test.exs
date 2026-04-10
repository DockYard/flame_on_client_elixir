defmodule FlameOn.Client.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias FlameOn.Client.CircuitBreaker

  setup do
    CircuitBreaker.init()
    :ok
  end

  describe "init/0" do
    test "initializes in enabled state" do
      refute CircuitBreaker.disabled?()
    end
  end

  describe "disable!/0" do
    test "sets the circuit breaker to disabled" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
    end
  end

  describe "enable!/0" do
    test "re-enables the circuit breaker after disable" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()

      CircuitBreaker.enable!()
      refute CircuitBreaker.disabled?()
    end
  end

  describe "disabled?/0" do
    test "returns false when enabled" do
      refute CircuitBreaker.disabled?()
    end

    test "returns true when disabled" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
    end

    test "toggle cycle works correctly" do
      refute CircuitBreaker.disabled?()
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
      CircuitBreaker.enable!()
      refute CircuitBreaker.disabled?()
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
    end
  end
end
