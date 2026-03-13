defmodule Flameon.IngestRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :traces, 1, repeated: true, type: Flameon.TraceProfile
end

defmodule Flameon.TraceProfile do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :trace_id, 1, type: :string, json_name: "traceId"
  field :event_name, 3, type: :string, json_name: "eventName"
  field :event_identifier, 4, type: :string, json_name: "eventIdentifier"
  field :profile, 5, type: Perftools.Profiles.Profile
end

defmodule Flameon.IngestResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :success, 1, type: :bool
  field :ingested, 2, type: :int32
  field :message, 3, type: :string
end
