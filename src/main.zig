const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");

pub fn read_file(al: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(al, std.math.maxInt(usize));
    return contents;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const al = gpa.allocator();

    const argv = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, argv);

    if (argv.len == 1) {
        std.debug.print("Usage: zlox <filename.lox>\n", .{});
        return 1;
    }
    const filepath = argv[1];

    var debug = false;
    if (argv.len > 2) {
        for (argv[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--debug")) {
                debug = true;
            }
        }
    }

    return run(al, filepath, debug);
}

pub fn run(al: std.mem.Allocator, filepath: []const u8, debug: bool) !u8 {
    const source = try read_file(al, filepath);
    defer al.free(source);

    var tokens = try tokenizer.tokenize(al, source);
    defer tokens.clearAndFree();

    if (debug) {
        for (tokens.items) |token| {
            std.debug.print("{d:3} {s:8} {}\n", .{
                token.start,
                source[token.start .. token.start + token.len],
                token.type,
            });
        }
    }

    const chunk = try compiler.compile(al, tokens.items, source);
    defer compiler.free_chunk(chunk);

    if (debug) {
        std.debug.print("{any} {any}\n", .{ chunk.data.items, chunk.constants.items });
    }

    try vm.interpret(al, chunk);
    return 0;
}

test {
    const al = std.testing.allocator;
    const retcode = try run(al, "./examples/math.lox", true);
    try std.testing.expect(retcode == 0);
}
