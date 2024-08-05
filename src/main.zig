const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const compiler = @import("compiler.zig");

pub fn read_file(al: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(al, std.math.maxInt(usize));
    return contents;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    const al = gpa.allocator();

    const argv = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, argv);

    if (argv.len == 1) {
        std.debug.print("Usage: zlox <filename.lox>\n", .{});
        return 1;
    }
    const source = try read_file(al, argv[1]);
    defer al.free(source);

    var tokens = try tokenizer.tokenize(al, source);
    defer tokens.clearAndFree();

    for (tokens.items) |token| {
        std.debug.print("{d:3} {s:8} {}\n", .{
            token.start,
            source[token.start .. token.start + token.len],
            token.type,
        });
    }

    const chunk = try compiler.compile(al, tokens.items, source);
    defer compiler.freeChunk(chunk);

    std.debug.print("{any} {any}\n", .{ chunk.data.items, chunk.constants.items });

    return 0;
}
