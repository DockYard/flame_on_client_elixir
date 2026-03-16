defmodule FlameOn.Client.ObanReporter do
  @moduledoc false

  alias FlameOn.Client.Errors

  def capture_exception(job, exception, stacktrace, opts \\ []) do
    Errors.capture_exception(
      exception,
      Keyword.merge(
        [
          stacktrace: stacktrace,
          handled: false,
          route: "oban.job",
          tags: oban_tags(job),
          contexts: oban_contexts(job),
          breadcrumbs: [oban_breadcrumb(job, Exception.message(exception))]
        ],
        opts
      )
    )
  end

  defp oban_tags(job) do
    %{
      worker: worker_name(job),
      queue: value(job, :queue)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp oban_contexts(job) do
    %{
      job_id: value(job, :id),
      attempt: value(job, :attempt),
      max_attempts: value(job, :max_attempts),
      args: value(job, :args, %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp oban_breadcrumb(job, message) do
    %{
      category: "oban",
      message: message,
      level: "error",
      data: %{
        worker: worker_name(job),
        queue: value(job, :queue),
        attempt: value(job, :attempt)
      }
    }
  end

  defp worker_name(job) do
    job
    |> value(:worker)
    |> case do
      worker when is_binary(worker) -> worker
      worker when is_atom(worker) -> inspect(worker)
      other -> to_string(other || "")
    end
  end

  defp value(job, key, default \\ nil) do
    Map.get(job, key) || Map.get(job, Atom.to_string(key)) || default
  end
end
