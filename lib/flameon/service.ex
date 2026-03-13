defmodule Flameon.FlameOnIngest.Service do
  use GRPC.Service, name: "flameon.FlameOnIngest"

  rpc(:Ingest, Flameon.IngestRequest, Flameon.IngestResponse)
end

defmodule Flameon.FlameOnIngest.Stub do
  use GRPC.Stub, service: Flameon.FlameOnIngest.Service
end
