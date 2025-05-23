const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RepositoryId = union(enum) {
    pub const Base: RepositoryId = .base;

    const base_repo_id: u8 = 0;
    const base_repo_name = "ffxiv";
    const expansion_repo_prefix = "ex";

    base,
    expansion: u8,

    pub fn fromIntId(id: u8) RepositoryId {
        if (id == base_repo_id) {
            return RepositoryId.Base;
        } else {
            return .{ .expansion = id };
        }
    }

    pub fn toIntId(self: RepositoryId) u8 {
        return switch (self) {
            .base => base_repo_id,
            .expansion => |expansion| expansion,
        };
    }

    pub fn toRepositoryString(self: RepositoryId, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .base => try std.fmt.allocPrint(allocator, "{s}", .{base_repo_name}),
            .expansion => |expansion| try std.fmt.allocPrint(allocator, "{s}{d}", .{ expansion_repo_prefix, expansion }),
        };
    }

    pub fn fromRepositoryString(repo_name: []const u8, fallback: bool) !RepositoryId {
        // Explicitly base repo
        if (std.mem.eql(u8, repo_name, base_repo_name)) {
            return RepositoryId.Base;
        }

        // Expansion pack repo
        if (std.mem.startsWith(u8, repo_name, expansion_repo_prefix)) {
            // Parse could fail if it's just a file which begins with "ex"
            const expack_id = std.fmt.parseInt(u8, repo_name[2..], 10) catch null;
            if (expack_id) |ex| {
                return .{ .expansion = ex };
            }
        }

        // If not explicitly base repo and not expansion pack, and no base fallback, return error
        if (!fallback) {
            return error.InvalidRepo;
        }

        // If not explicitly base repo and not expansion pack, but fallback is allowed, return base repo ID
        return RepositoryId.Base;
    }
};

test "basic fromIntId" {
    {
        const repo_id = RepositoryId.fromIntId(1);
        try std.testing.expectEqual(RepositoryId{
            .expansion = 1,
        }, repo_id);
    }

    {
        const repo_id = RepositoryId.fromIntId(0);
        try std.testing.expectEqual(RepositoryId.Base, repo_id);
    }
}

test "basic toIntId" {
    {
        const repo_id = RepositoryId.fromIntId(1);
        try std.testing.expectEqual(1, repo_id.toIntId());
    }

    {
        const repo_id = RepositoryId.Base;
        try std.testing.expectEqual(0, repo_id.toIntId());
    }
}

test "basic toRepositoryString" {
    const allocator = std.testing.allocator;

    {
        const repo_id = RepositoryId.Base;
        const id = try repo_id.toRepositoryString(allocator);
        defer allocator.free(id);
        try std.testing.expectEqualStrings("ffxiv", id);
    }

    {
        const repo_id = RepositoryId.fromIntId(1);
        const id = try repo_id.toRepositoryString(allocator);
        defer allocator.free(id);
        try std.testing.expectEqualStrings("ex1", id);
    }
}

test "basic fromRepositoryString" {
    {
        const repo_id = try RepositoryId.fromRepositoryString("ffxiv", false);
        try std.testing.expectEqual(RepositoryId.Base, repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("ex1", false);
        try std.testing.expectEqual(RepositoryId.fromIntId(1), repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("ex2", false);
        try std.testing.expectEqual(RepositoryId.fromIntId(2), repo_id);
    }

    {
        const repo_id = RepositoryId.fromRepositoryString("explodey", false);
        try std.testing.expectError(error.InvalidRepo, repo_id);
    }
}

test "fallback fromRepositoryString" {
    {
        const repo_id = try RepositoryId.fromRepositoryString("ex1", true);
        try std.testing.expectEqual(RepositoryId.fromIntId(1), repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("ex2", true);
        try std.testing.expectEqual(RepositoryId.fromIntId(2), repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("explodey", true);
        try std.testing.expectEqual(RepositoryId.Base, repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("ffxiv", true);
        try std.testing.expectEqual(RepositoryId.Base, repo_id);
    }

    {
        const repo_id = try RepositoryId.fromRepositoryString("unknown", true);
        try std.testing.expectEqual(RepositoryId.Base, repo_id);
    }
}
