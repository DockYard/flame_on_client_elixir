defmodule Perftools.Profiles.Profile do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :sample_type, 1,
    repeated: true,
    type: Perftools.Profiles.ValueType,
    json_name: "sampleType"

  field :sample, 2, repeated: true, type: Perftools.Profiles.Sample
  field :mapping, 3, repeated: true, type: Perftools.Profiles.Mapping
  field :location, 4, repeated: true, type: Perftools.Profiles.Location
  field :function, 5, repeated: true, type: Perftools.Profiles.Function
  field :string_table, 6, repeated: true, type: :string, json_name: "stringTable"
  field :drop_frames, 7, type: :int64, json_name: "dropFrames"
  field :keep_frames, 8, type: :int64, json_name: "keepFrames"
  field :time_nanos, 9, type: :int64, json_name: "timeNanos"
  field :duration_nanos, 10, type: :int64, json_name: "durationNanos"
  field :period_type, 11, type: Perftools.Profiles.ValueType, json_name: "periodType"
  field :period, 12, type: :int64
  field :comment, 13, repeated: true, type: :int64
  field :default_sample_type, 15, type: :int64, json_name: "defaultSampleType"
end

defmodule Perftools.Profiles.ValueType do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :type, 1, type: :int64
  field :unit, 2, type: :int64
end

defmodule Perftools.Profiles.Sample do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :location_id, 1, repeated: true, type: :uint64, json_name: "locationId"
  field :value, 2, repeated: true, type: :int64
  field :label, 3, repeated: true, type: Perftools.Profiles.Label
end

defmodule Perftools.Profiles.Label do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :int64
  field :str, 2, type: :int64
  field :num, 3, type: :int64
  field :num_unit, 4, type: :int64, json_name: "numUnit"
end

defmodule Perftools.Profiles.Mapping do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :id, 1, type: :uint64
  field :memory_start, 2, type: :uint64, json_name: "memoryStart"
  field :memory_limit, 3, type: :uint64, json_name: "memoryLimit"
  field :file_offset, 4, type: :uint64, json_name: "fileOffset"
  field :filename, 5, type: :int64
  field :build_id, 6, type: :int64, json_name: "buildId"
  field :has_functions, 7, type: :bool, json_name: "hasFunctions"
  field :has_filenames, 8, type: :bool, json_name: "hasFilenames"
  field :has_line_numbers, 9, type: :bool, json_name: "hasLineNumbers"
  field :has_inline_frames, 10, type: :bool, json_name: "hasInlineFrames"
end

defmodule Perftools.Profiles.Location do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :id, 1, type: :uint64
  field :mapping_id, 2, type: :uint64, json_name: "mappingId"
  field :address, 3, type: :uint64
  field :line, 4, repeated: true, type: Perftools.Profiles.Line
  field :is_folded, 5, type: :bool, json_name: "isFolded"
end

defmodule Perftools.Profiles.Line do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :function_id, 1, type: :uint64, json_name: "functionId"
  field :line, 2, type: :int64
end

defmodule Perftools.Profiles.Function do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :id, 1, type: :uint64
  field :name, 2, type: :int64
  field :system_name, 3, type: :int64, json_name: "systemName"
  field :filename, 4, type: :int64
  field :start_line, 5, type: :int64, json_name: "startLine"
end
