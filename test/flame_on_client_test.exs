defmodule FlameOnClientTest do
  use ExUnit.Case

  describe "config/0" do
    test "reads api_key from application config" do
      original = Application.get_env(:flame_on_client, :api_key)

      on_exit(fn ->
        Application.put_env(:flame_on_client, :api_key, original)
        System.delete_env("FLAMEON_API_KEY")
      end)

      Application.put_env(:flame_on_client, :api_key, "config-api-key")

      assert FlameOn.Client.config().api_key == "config-api-key"
    end

    test "reads api_key from FLAMEON_API_KEY env var" do
      original = Application.get_env(:flame_on_client, :api_key)

      on_exit(fn ->
        Application.put_env(:flame_on_client, :api_key, original)
        System.delete_env("FLAMEON_API_KEY")
      end)

      Application.put_env(:flame_on_client, :api_key, nil)
      System.put_env("FLAMEON_API_KEY", "env-api-key")

      assert FlameOn.Client.env_or_config(:api_key, nil) == "env-api-key"
    end
  end
end
