const std = @import("std");

const calyx = @import("calyx");

test "sqpack" {
    const game_data = try calyx.GameData.init(std.testing.allocator, .{});
    defer game_data.deinit();

    {
        const game_path = "chara/equipment/e0436/material/v0001/mt_c0101e0436_top_a.mtrl";
        const expected_hash = 0x9CEAFA0;

        std.log.info("Testing standard file: {s}", .{game_path});

        const contents = try game_data.getFileContents(std.testing.allocator, game_path);
        defer std.testing.allocator.free(contents);

        const hash = calyx.core.hash.crc32(contents);

        try std.testing.expectEqual(expected_hash, hash);
    }

    {
        const game_path = "chara/equipment/e0436/texture/v01_c0101e0436_top_m.tex";
        const expected_hash = 0xAA576DD;

        std.log.info("Testing tex file: {s}", .{game_path});

        const contents = try game_data.getFileContents(std.testing.allocator, game_path);
        defer std.testing.allocator.free(contents);

        const hash = calyx.core.hash.crc32(contents);

        try std.testing.expectEqual(expected_hash, hash);
    }

    {
        const game_path = "chara/equipment/e0436/model/c0101e0436_top.mdl";
        const expected_hash = 0xCE430290;

        std.log.info("Testing mdl file: {s}", .{game_path});

        const contents = try game_data.getFileContents(std.testing.allocator, game_path);
        defer std.testing.allocator.free(contents);

        const hash = calyx.core.hash.crc32(contents);

        try std.testing.expectEqual(expected_hash, hash);
    }
}
