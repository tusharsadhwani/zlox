const std = @import("std");

const compiler = @import("compiler.zig");
const OpCode = compiler.OpCode;

const VM = struct {
    chunk: *compiler.Chunk,
    stack: std.ArrayList(f32),
    ip: [*]u8,
};

fn next_byte(vm: *VM) u8 {
    const byte = vm.ip[0];
    vm.ip += 1;
    return byte;
}

pub fn interpret(al: std.mem.Allocator, chunk: *compiler.Chunk) !void {
    var vm = VM{
        .chunk = chunk,
        .stack = std.ArrayList(f32).init(al),
        .ip = chunk.data.items.ptr,
    };

    while (true) {
        const x = next_byte(&vm);
        const opcode: OpCode = @enumFromInt(x);
        switch (opcode) {
            OpCode.CONSTANT => {
                const constant_index = next_byte(&vm);
                try vm.stack.append(vm.chunk.constants.items[constant_index]);
            },
            OpCode.ADD => {
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(a + b);
            },
            OpCode.SUBTRACT => {
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(a - b);
            },
            OpCode.MULTIPLY => {
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(a * b);
            },
            OpCode.DIVIDE => {
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(a / b);
            },
            OpCode.NEGATE => {
                try vm.stack.append(-vm.stack.pop());
            },
            OpCode.RETURN => {
                std.debug.print("{d}\n", .{vm.stack.pop()});
                if (vm.stack.items.len != 0) {
                    return error.StackNotEmpty;
                }
                break;
            },
        }
    }
}
