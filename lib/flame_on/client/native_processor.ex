defmodule FlameOn.Client.NativeProcessor do
  @moduledoc """
  NIF bridge to the Zig-based flame graph processor.

  Replaces ProfileFilter + PprofEncoder with a single native call
  that runs on a dirty CPU scheduler. On any error or when the NIF
  is unavailable, callers should fall back to the Elixir implementation.

  ## Architecture

  The NIF receives the collapsed stacks map (`%{binary => integer}`)
  and a threshold float, processes them in Zig-managed memory (outside
  the BEAM heap), and returns a serialized pprof Profile protobuf binary.

  The NIF runs on a dirty CPU scheduler because profile processing
  can take 10-100ms for large traces.

  ## Usage

      case NativeProcessor.process_stacks(stacks, threshold) do
        {:ok, profile_binary} -> profile_binary
        {:error, _reason} -> elixir_fallback(stacks, threshold)
      end

  ## Availability

  The NIF is optional. When the Zig processor library is not compiled
  (e.g., during development or on platforms without Zig), `available?/0`
  returns false and `process_stacks/2` returns `{:error, :nif_not_loaded}`.
  """

  require Logger

  @on_load :load_nif

  @doc false
  def load_nif do
    path =
      :flame_on_client
      |> :code.priv_dir()
      |> Path.join("native/native_processor")

    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok ->
        :ok

      {:error, {:load_failed, _}} ->
        Logger.debug("[FlameOn] Native processor NIF not available, using Elixir fallback")
        :ok

      {:error, {:reload, _}} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "[FlameOn] Native processor NIF load failed: #{inspect(reason)}, using Elixir fallback"
        )

        :ok
    end
  end

  @doc """
  Returns true if the native processor NIF is loaded and available.
  """
  @spec available?() :: boolean()
  def available? do
    # This function is replaced by the NIF when loaded.
    # If we reach this Elixir body, the NIF is not loaded.
    false
  end

  @doc """
  Process collapsed stacks into a pprof Profile protobuf binary.

  Runs on a dirty CPU scheduler to avoid blocking normal schedulers.

  ## Arguments

    * `stacks` - Map of `%{stack_path => duration_us}` where stack_path
      is a semicolon-separated string and duration_us is a non-negative integer.
    * `threshold` - Float threshold for filtering small functions (e.g., 0.01 for 1%).

  ## Returns

    * `{:ok, binary}` - A serialized `Perftools.Profiles.Profile` protobuf binary
    * `{:error, reason}` - An error occurred; `reason` is an atom
  """
  @spec process_stacks(map(), float()) :: {:ok, binary()} | {:error, atom()}
  def process_stacks(_stacks, _threshold) do
    {:error, :nif_not_loaded}
  end
end
