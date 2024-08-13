const std = @import("std");

const GlobalContext = @import("context.zig").GlobalContext;
const tokenizer = @import("tokenizer.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");

pub fn read_file(al: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(al, std.math.maxInt(usize));
    return contents;
}

pub fn run(al: std.mem.Allocator, source: []u8, writer: std.io.AnyWriter, debug: bool) !void {
    var tokens = try tokenizer.tokenize(al, source);
    defer tokens.deinit();

    if (debug) {
        for (tokens.items) |token| {
            std.debug.print("{d:3} {s:15} {}\n", .{
                token.start,
                source[token.start .. token.start + token.len],
                token.type,
            });
        }
    }

    var ctx = try GlobalContext.init(al);
    defer ctx.free();

    const chunk = try compiler.compile(ctx, tokens.items, source);
    defer chunk.free();

    if (debug) {
        var index: usize = 0;

        while (index < chunk.data.items.len) {
            const opcode: compiler.OpCode = @enumFromInt(chunk.data.items[index]);
            switch (opcode) {
                compiler.OpCode.CONSTANT => {
                    const constant_index = chunk.data.items[index + 1];
                    const constant = chunk.constants.items[constant_index];
                    const formatted_constant = try vm.format_constant(al, constant);
                    defer al.free(formatted_constant);
                    std.debug.print("{s:<15} {s}\n", .{ @tagName(opcode), formatted_constant });
                    index += 2;
                },
                else => {
                    std.debug.print("{s}\n", .{@tagName(opcode)});
                    index += 1;
                },
            }
        }
    }

    try vm.interpret(ctx, chunk, writer);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const al = gpa.allocator();

    const argv = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, argv);

    if (argv.len == 1) {
        std.debug.print("Usage: zlox <filename.lox>\n", .{});
        std.process.exit(1);
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

    const source = try read_file(al, filepath);
    defer al.free(source);

    const stdout = std.io.getStdOut().writer().any();
    try run(al, source, stdout, debug);
}

test {
    const al = std.testing.allocator;
    var output = std.ArrayList(u8).init(al);
    defer output.deinit();
    const source = try std.fmt.allocPrint(al, "print -1.2 + 3 * 5 < 3 == false;", .{});
    defer al.free(source);
    try run(al, source, output.writer().any(), false);
    try std.testing.expectEqualStrings("true\n", output.items);
}
test {
    const al = std.testing.allocator;
    var output = std.ArrayList(u8).init(al);
    defer output.deinit();
    const source = try std.fmt.allocPrint(al, "print -1.2 + 3 * 5 < 3 == \"foobar\";", .{});
    defer al.free(source);
    try run(al, source, output.writer().any(), false);
    try std.testing.expectEqualStrings("false\n", output.items);
}
test {
    const al = std.testing.allocator;
    var output = std.ArrayList(u8).init(al);
    defer output.deinit();
    const source = try std.fmt.allocPrint(al, "print \"foo\" + \"bar\" == \"foobar\";", .{});
    defer al.free(source);
    try run(al, source, output.writer().any(), false);
    try std.testing.expectEqualStrings("true\n", output.items);
}
test {
    const al = std.testing.allocator;
    var output = std.ArrayList(u8).init(al);
    defer output.deinit();
    const source = try std.fmt.allocPrint(al, "print \"foo\" + \"bar\" == \"foo\" + \"bar\";", .{});
    defer al.free(source);
    try run(al, source, output.writer().any(), false);
    try std.testing.expectEqualStrings("true\n", output.items);
}
