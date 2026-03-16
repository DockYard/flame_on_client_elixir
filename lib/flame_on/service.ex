defmodule FlameOn.FlameOnIngest.Service do
  use GRPC.Service, name: "flame_on.FlameOnIngest"

  rpc(:Ingest, FlameOn.IngestRequest, FlameOn.IngestResponse)
end

defmodule FlameOn.FlameOnIngest.Stub do
  use GRPC.Stub, service: FlameOn.FlameOnIngest.Service
end

defmodule FlameOn.FlameOnErrorIngest.Service do
  use GRPC.Service, name: "flame_on.FlameOnErrorIngest"

  rpc(:IngestErrors, FlameOn.IngestErrorsRequest, FlameOn.IngestErrorsResponse)
end

defmodule FlameOn.FlameOnErrorIngest.Stub do
  use GRPC.Stub, service: FlameOn.FlameOnErrorIngest.Service
end
