const std = @import("std");

pub const ScanWarning = struct {
    rel_path: []const u8,
    reason: []const u8,
};

/// Move two ArrayLists into owned slices. If moving the second list fails,
/// release the first slice that has already left its list.
pub fn takeTwoSlices(
    allocator: std.mem.Allocator,
    first: anytype,
    second: anytype,
    free_first: anytype,
) error{OutOfMemory}!@TypeOf(.{ .first = first.items, .second = second.items }) {
    const first_slice = first.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer free_first(allocator, first_slice);

    const second_slice = second.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .first = first_slice, .second = second_slice };
}

/// Duplicate a warning slice, rolling back the complete allocation on failure.
pub fn duplicateWarnings(allocator: std.mem.Allocator, warnings: []const ScanWarning) ![]ScanWarning {
    const owned = try allocator.alloc(ScanWarning, warnings.len);
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |warning| {
            allocator.free(warning.rel_path);
            allocator.free(warning.reason);
        }
        allocator.free(owned);
    }

    for (warnings) |warning| {
        const rel_path = try allocator.dupe(u8, warning.rel_path);
        const reason = allocator.dupe(u8, warning.reason) catch |err| {
            allocator.free(rel_path);
            return err;
        };
        owned[count] = .{ .rel_path = rel_path, .reason = reason };
        count += 1;
    }
    return owned;
}

pub fn freeWarnings(allocator: std.mem.Allocator, warnings: []ScanWarning) void {
    for (warnings) |warning| {
        allocator.free(warning.rel_path);
        allocator.free(warning.reason);
    }
    allocator.free(warnings);
}

fn freeBytes(allocator: std.mem.Allocator, values: []u8) void {
    allocator.free(values);
}

fn exerciseTransfer(failing: *std.testing.FailingAllocator) !bool {
    const allocator = failing.allocator();
    var first: std.ArrayList(u8) = .empty;
    var second: std.ArrayList(u8) = .empty;
    defer first.deinit(allocator);
    defer second.deinit(allocator);

    try first.ensureTotalCapacity(allocator, 4);
    try second.ensureTotalCapacity(allocator, 4);
    first.appendAssumeCapacity(1);
    second.appendAssumeCapacity(2);

    const result = takeTwoSlices(allocator, &first, &second, freeBytes) catch {
        return first.items.len == 0 and second.items.len != 0;
    };
    defer allocator.free(result.first);
    defer allocator.free(result.second);
    return false;
}

test "second slice transfer failure frees the first transferred slice" {
    var saw_second_transfer_failure = false;
    for (0..8) |fail_index| {
        for (0..4) |resize_fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
                .resize_fail_index = resize_fail_index,
            });
            saw_second_transfer_failure = (exerciseTransfer(&failing) catch false) or saw_second_transfer_failure;
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
    try std.testing.expect(saw_second_transfer_failure);
}

test "warning duplication frees partial copies on allocation failure" {
    const source = [_]ScanWarning{
        .{ .rel_path = "one.html", .reason = "bad json" },
        .{ .rel_path = "two.html", .reason = "missing tag" },
    };
    var induced_failures: usize = 0;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (duplicateWarnings(failing.allocator(), &source)) |warnings| {
            freeWarnings(failing.allocator(), warnings);
        } else |_| {}
        if (failing.has_induced_failure) induced_failures += 1;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(induced_failures > 0);
}
