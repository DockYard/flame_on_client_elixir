defmodule FlameOn.IngestRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:traces, 1, repeated: true, type: FlameOn.TraceProfile)
end

defmodule FlameOn.TraceProfile do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:trace_id, 1, type: :string, json_name: "traceId")
  field(:event_name, 3, type: :string, json_name: "eventName")
  field(:event_identifier, 4, type: :string, json_name: "eventIdentifier")
  field(:profile, 5, type: Perftools.Profiles.Profile)
end

defmodule FlameOn.IngestResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:ingested, 2, type: :int32)
  field(:message, 3, type: :string)
end

defmodule FlameOn.IngestErrorsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:events, 1, repeated: true, type: FlameOn.ErrorEvent)
end

defmodule FlameOn.IngestErrorsResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:ingested, 2, type: :int32)
  field(:warnings, 3, repeated: true, type: :string)
end

defmodule FlameOn.KeyValue do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule FlameOn.StackFrame do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:function, 1, type: :string)
  field(:module, 2, type: :string)
  field(:file, 3, type: :string)
  field(:line, 4, type: :uint32)
  field(:column, 5, type: :uint32)
  field(:in_app, 6, type: :bool, json_name: "inApp")
  field(:abs_path, 7, type: :string, json_name: "absPath")
  field(:context_line, 8, type: :string, json_name: "contextLine")
  field(:pre_context, 9, repeated: true, type: :string, json_name: "preContext")
  field(:post_context, 10, repeated: true, type: :string, json_name: "postContext")
end

defmodule FlameOn.StackTrace do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:frames, 1, repeated: true, type: FlameOn.StackFrame)
end

defmodule FlameOn.Exception do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:type, 1, type: :string)
  field(:value, 2, type: :string)
  field(:stack_trace, 3, type: FlameOn.StackTrace, json_name: "stackTrace")
end

defmodule FlameOn.RequestContext do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:method, 1, type: :string)
  field(:url, 2, type: :string)
  field(:route, 3, type: :string)
  field(:headers, 4, repeated: true, type: FlameOn.KeyValue)
  field(:remote_addr, 5, type: :string, json_name: "remoteAddr")
end

defmodule FlameOn.UserContext do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:email, 2, type: :string)
  field(:username, 3, type: :string)
  field(:ip_address, 4, type: :string, json_name: "ipAddress")
end

defmodule FlameOn.Breadcrumb do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:timestamp, 1, type: Google.Protobuf.Timestamp)
  field(:category, 2, type: :string)
  field(:message, 3, type: :string)
  field(:type, 4, type: :string)
  field(:level, 5, type: :string)
  field(:data, 6, repeated: true, type: FlameOn.KeyValue)
end

defmodule FlameOn.ErrorEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:event_id, 1, type: :string, json_name: "eventId")
  field(:occurred_at, 2, type: Google.Protobuf.Timestamp, json_name: "occurredAt")
  field(:platform, 3, type: :string)
  field(:environment, 4, type: :string)
  field(:service, 5, type: :string)
  field(:route, 6, type: :string)
  field(:release, 7, type: :string)
  field(:severity, 8, type: :string)
  field(:message, 9, type: :string)
  field(:handled, 10, type: :bool)
  field(:trace_id, 11, type: :string, json_name: "traceId")
  field(:span_id, 12, type: :string, json_name: "spanId")
  field(:fingerprint, 13, repeated: true, type: :string)
  field(:exceptions, 14, repeated: true, type: FlameOn.Exception)
  field(:request, 15, type: FlameOn.RequestContext)
  field(:user, 16, type: FlameOn.UserContext)
  field(:breadcrumbs, 17, repeated: true, type: FlameOn.Breadcrumb)
  field(:tags, 18, repeated: true, type: FlameOn.KeyValue)
  field(:contexts, 19, repeated: true, type: FlameOn.KeyValue)
end
