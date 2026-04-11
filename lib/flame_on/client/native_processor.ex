defmodule FlameOn.Client.NativeProcessor do
  @moduledoc """
  Downloads and loads the precompiled Zig NIF for native profile processing.
  Falls back to Elixir ProfileFilter + PprofEncoder when the NIF is unavailable.
  """

  require Logger

  @processor_version Application.compile_env(:flame_on_client, :processor_version, "0.0.1")
  @github_repo "DockYard/flame_on_processor"
  @nif_name "libflame_on_processor_nif"

  # Platform detection

  @doc """
  Returns the target triple string for the current platform (e.g. "aarch64-macos").
  """
  def target do
    "#{arch()}-#{os()}"
  end

  defp arch do
    arch_str = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      String.starts_with?(arch_str, "aarch64") -> "aarch64"
      String.starts_with?(arch_str, "arm") -> "aarch64"
      String.contains?(arch_str, "x86_64") -> "x86_64"
      String.contains?(arch_str, "amd64") -> "x86_64"
      true -> "unknown"
    end
  end

  defp os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "macos"
      _ -> "unknown"
    end
  end

  # NIF path resolution

  @doc """
  Returns the path to the NIF shared library (without extension).
  Used by `:erlang.load_nif/2`.
  """
  def nif_path do
    priv =
      case :code.priv_dir(:flame_on_client) do
        {:error, _} -> build_priv_dir()
        path -> List.to_string(path)
      end

    Path.join([priv, "native", @nif_name])
  end

  defp nif_so_path do
    # Erlang's load_nif always appends .so, even on macOS
    nif_path() <> ".so"
  end

  defp build_priv_dir do
    Path.join([Mix.Project.build_path(), "lib", "flame_on_client", "priv"])
  end

  defp native_dir do
    Path.join(build_priv_dir(), "native")
  end

  # Download URL

  defp download_url(target_triple) do
    "https://github.com/#{@github_repo}/releases/download/v#{@processor_version}/flame_on_processor-nif-#{target_triple}.tar.gz"
  end

  @doc """
  Ensures the precompiled NIF binary is available on disk.
  Downloads it from GitHub releases if not already cached.
  Returns `true` if the NIF file exists, `false` otherwise.
  """
  def ensure_precompiled do
    if File.exists?(nif_so_path()) do
      true
    else
      case download_precompiled() do
        :ok ->
          true

        {:error, reason} ->
          Logger.info(
            "[FlameOn] Precompiled NIF not available (#{reason}), using Elixir fallback"
          )

          false
      end
    end
  end

  defp download_precompiled do
    target = target()

    if target =~ "unknown" do
      {:error, "unsupported platform: #{target}"}
    else
      url = download_url(target)
      dest = native_dir()
      File.mkdir_p!(dest)
      download_and_extract(url, dest)
    end
  end

  defp download_and_extract(url, dest) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    url_charlist = String.to_charlist(url)
    http_options = [ssl: ssl_opts()]
    options = [body_format: :binary]

    Logger.info("[FlameOn] Downloading precompiled NIF from #{url}")

    case :httpc.request(:get, {url_charlist, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        result = :erl_tar.extract({:binary, body}, [:compressed, {:cwd, String.to_charlist(dest)}])

        # Erlang's load_nif always appends .so, even on macOS.
        # Rename .dylib to .so if needed.
        dylib_path = Path.join(dest, @nif_name <> ".dylib")
        so_path = Path.join(dest, @nif_name <> ".so")

        if File.exists?(dylib_path) and not File.exists?(so_path) do
          File.rename(dylib_path, so_path)
        end

        result

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp ssl_opts do
    # OTP 25+
    certs = :public_key.cacerts_get()

    [
      verify: :verify_peer,
      cacerts: certs,
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  rescue
    _ -> []
  end

  # NIF loading

  @on_load :load_nif

  @doc false
  def load_nif do
    if ensure_precompiled() do
      path = nif_path() |> String.to_charlist()

      case :erlang.load_nif(path, 0) do
        :ok ->
          :ok

        {:error, {:reload, _}} ->
          :ok

        {:error, reason} ->
          Logger.info(
            "[FlameOn] NIF load failed: #{inspect(reason)}, using Elixir fallback"
          )

          # Don't crash the module — fall back to Elixir implementation
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Returns true if the native processor NIF is loaded and available.
  """
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _}, process_stacks(%{"test;a" => 1000}, 0.01))
  end

  # -- erl_tracer NIF interface --
  #
  # These functions support the Phase 5 erl_tracer NIF integration.
  # When the NIF is loaded, these stubs are replaced by native implementations
  # that write trace events to a lock-free ring buffer in native memory,
  # bypassing the BEAM message queue entirely.

  @doc """
  Returns true if the erl_tracer NIF callbacks are loaded and functional.

  This checks whether the ring buffer management functions are available,
  which implies the erl_tracer callbacks (enabled/3, trace/5) are also loaded
  since they are part of the same shared library.
  """
  @spec tracer_available?() :: boolean()
  def tracer_available? do
    case create_trace_buffer(1024) do
      {:ok, _buffer} -> true
      _ -> false
    end
  end

  @doc """
  erl_tracer behavior callback: called by the VM before generating a trace event.

  When the NIF is loaded, this checks the ring buffer fill level and returns:
  - `:trace` — generate the event and call trace/5
  - `:discard` — skip this event but keep tracing (backpressure)
  - `:remove` — remove all trace flags from this process

  The fallback returns `:remove` to signal that NIF tracing is not available.
  """
  def enabled(_trace_tag, _tracer_state, _tracee), do: :remove

  @doc """
  erl_tracer behavior callback: called by the VM with actual trace event data.

  When the NIF is loaded, this packs the event into a 32-byte struct and writes
  it to the ring buffer via atomic operations (~200ns per event).

  The fallback is a no-op since `:remove` from enabled/3 prevents this from
  being called when the NIF is not loaded.
  """
  def trace(_trace_tag, _tracer_state, _tracee, _trace_term, _opts), do: :ok

  @doc """
  Allocate a ring buffer for trace events in native memory.

  Returns `{:ok, buffer_ref}` where `buffer_ref` is an opaque NIF resource
  reference, or `{:error, reason}`.

  ## Arguments

    * `size_bytes` - Size of the ring buffer in bytes. 4MB (~125K events) is
      the recommended default.
  """
  @spec create_trace_buffer(pos_integer()) :: {:ok, reference()} | {:error, atom()}
  def create_trace_buffer(_size_bytes), do: {:error, :nif_not_loaded}

  @doc """
  Read up to `max_count` events from the ring buffer.

  Advances the read pointer. Returns `{:ok, events}` where events is a list
  of tuples. The exact tuple format depends on the event type:

    * `{:call, {module, function, arity}, timestamp_us}`
    * `{:return_to, {module, function, arity}, timestamp_us}`
    * `{:out, {module, function, arity}, timestamp_us}`
    * `{:in, {module, function, arity}, timestamp_us}`

  ## Arguments

    * `buffer` - Ring buffer reference from `create_trace_buffer/1`
    * `max_count` - Maximum number of events to drain in this batch
  """
  @spec drain_trace_buffer(reference(), pos_integer()) :: {:ok, list()} | {:error, atom()}
  def drain_trace_buffer(_buffer, _max_count), do: {:error, :nif_not_loaded}

  @doc """
  Returns statistics about the ring buffer.

  Returns `{write_pos, read_pos, capacity, overflow_count}` for monitoring.

  ## Arguments

    * `buffer` - Ring buffer reference from `create_trace_buffer/1`
  """
  @spec trace_buffer_stats(reference()) :: tuple() | {:error, atom()}
  def trace_buffer_stats(_buffer), do: {:error, :nif_not_loaded}

  @doc """
  Set the active flag on a ring buffer.

  When active is `false`, the `enabled/3` callback returns `:remove`, telling
  the VM to remove all trace flags from the traced process.

  ## Arguments

    * `buffer` - Ring buffer reference from `create_trace_buffer/1`
    * `active` - Boolean flag
  """
  @spec set_trace_active(reference(), boolean()) :: :ok | {:error, atom()}
  def set_trace_active(_buffer, _active), do: {:error, :nif_not_loaded}

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
