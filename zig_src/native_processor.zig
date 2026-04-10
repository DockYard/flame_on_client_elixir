const beam = @import("beam");
const e = @import("erl_nif");
const std = @import("std");
const processor = @import("flame_on_processor");

/// NIF entry point: process collapsed stacks into a pprof protobuf binary.
///
/// Arguments:
///   stacks_term   - Elixir map %{binary() => non_neg_integer()}
///                   where keys are stack paths and values are cumulative durations in microseconds
///   threshold_term - float, the function_length_threshold (e.g. 0.01 for 1%)
///
/// Returns:
///   {:ok, binary()}   on success (the binary is a serialized pprof Profile protobuf)
///   {:error, reason}  on failure (reason is an atom)
pub fn process_stacks(stacks_term: beam.term, threshold_term: beam.term) beam.term {
    return do_process_stacks(stacks_term, threshold_term) catch |err| {
        return beam.make(.{ .@"error", error_to_atom(err) }, .{});
    };
}

fn do_process_stacks(stacks_term: beam.term, threshold_term: beam.term) !beam.term {
    const threshold = beam.get(f64, threshold_term, .{}) catch {
        return beam.make(.{ .@"error", .bad_threshold }, .{});
    };

    // Convert the Elixir map to parallel slices of paths and durations
    // using the low-level erl_nif map iterator API.
    const alloc = beam.allocator;

    var map_size: usize = 0;
    if (e.enif_get_map_size(beam.context.env, stacks_term, &map_size) == 0) {
        return beam.make(.{ .@"error", .bad_stacks }, .{});
    }

    // Allocate arrays for paths and durations
    const paths = try alloc.alloc([]const u8, map_size);
    defer alloc.free(paths);
    const durations = try alloc.alloc(u64, map_size);
    defer alloc.free(durations);

    // Iterate the map using erl_nif iterator
    var iter: e.ErlNifMapIterator = undefined;
    if (e.enif_map_iterator_create(beam.context.env, stacks_term, &iter, e.ERL_NIF_MAP_ITERATOR_FIRST) == 0) {
        return beam.make(.{ .@"error", .bad_stacks }, .{});
    }
    defer e.enif_map_iterator_destroy(beam.context.env, &iter);

    var i: usize = 0;
    var key: beam.term = undefined;
    var value: beam.term = undefined;
    while (e.enif_map_iterator_get_pair(beam.context.env, &iter, &key, &value) != 0) : ({
        _ = e.enif_map_iterator_next(beam.context.env, &iter);
    }) {
        // Get the binary key (stack path)
        var bin: e.ErlNifBinary = undefined;
        if (e.enif_inspect_binary(beam.context.env, key, &bin) == 0) {
            // Try iolist_to_binary for non-binary keys
            if (e.enif_inspect_iolist_as_binary(beam.context.env, key, &bin) == 0) {
                continue; // Skip entries with non-binary keys
            }
        }
        paths[i] = bin.data[0..bin.size];

        // Get the integer value (duration in microseconds)
        var dur: c_long = 0;
        if (e.enif_get_long(beam.context.env, value, &dur) == 0) {
            var dur_uint: c_ulong = 0;
            if (e.enif_get_ulong(beam.context.env, value, &dur_uint) == 0) {
                continue; // Skip non-integer values
            }
            durations[i] = @intCast(dur_uint);
        } else {
            durations[i] = @intCast(@as(u64, @bitCast(@as(i64, dur))));
        }
        i += 1;
    }

    const actual_count = i;

    // Call the Zig processor library
    const result = try processor.process(
        alloc,
        paths[0..actual_count],
        durations[0..actual_count],
        threshold,
    );
    defer alloc.free(result);

    // Return as {:ok, binary}
    return beam.make(.{ .ok, result }, .{});
}

fn error_to_atom(err: anyerror) beam.term {
    _ = err;
    return beam.make(.processing_failed, .{});
}
