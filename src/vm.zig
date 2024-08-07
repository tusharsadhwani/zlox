const std = @import("std");

const compiler = @import("compiler.zig");
const LoxConstant = compiler.LoxConstant;
const LoxType = compiler.LoxType;
const LoxValue = compiler.LoxValue;
const LoxObject = compiler.LoxObject;
const LoxString = compiler.LoxString;
const OpCode = compiler.OpCode;

const VM = struct {
    chunk: *compiler.Chunk,
    stack: compiler.ConstantStack,
    ip: [*]u8,

    fn peek(self: *VM, index: usize) LoxConstant {
        return self.stack.items[self.stack.items.len - 1 - index];
    }
};

fn next_byte(vm: *VM) u8 {
    const byte = vm.ip[0];
    vm.ip += 1;
    return byte;
}

fn unary_number_check(vm: *VM) !void {
    if (vm.peek(0) != .NUMBER) {
        return error.RuntimeError;
    }
}
fn binary_number_check(vm: *VM) !void {
    if (vm.peek(0) != .NUMBER or vm.peek(1) != .NUMBER) {
        return error.RuntimeError;
    }
}

pub fn format_constant(al: std.mem.Allocator, constant: LoxConstant) ![]u8 {
    return try switch (constant) {
        LoxType.NUMBER => std.fmt.allocPrint(al, "{d}", .{constant.NUMBER}),
        LoxType.BOOLEAN => std.fmt.allocPrint(al, "{}", .{constant.BOOLEAN}),
        LoxType.NIL => std.fmt.allocPrint(al, "nil", .{}),
        LoxType.OBJECT => switch (constant.OBJECT.type) {
            LoxObject.Type.STRING => {
                const formatted_constant = try std.fmt.allocPrint(
                    al,
                    "{s}",
                    .{constant.OBJECT.as_string().string},
                );
                return formatted_constant;
            },
        },
    };
}

pub fn interpret(al: std.mem.Allocator, chunk: *compiler.Chunk) ![]u8 {
    var vm = VM{
        .chunk = chunk,
        .stack = compiler.ConstantStack.init(al),
        .ip = chunk.data.items.ptr,
    };
    defer vm.stack.deinit();

    while (true) {
        const x = next_byte(&vm);
        const opcode: OpCode = @enumFromInt(x);
        switch (opcode) {
            OpCode.CONSTANT => {
                const constant_index = next_byte(&vm);
                try vm.stack.append(vm.chunk.constants.items[constant_index]);
            },
            OpCode.ADD => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .NUMBER = a.NUMBER + b.NUMBER });
            },
            OpCode.SUBTRACT => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .NUMBER = a.NUMBER - b.NUMBER });
            },
            OpCode.MULTIPLY => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .NUMBER = a.NUMBER * b.NUMBER });
            },
            OpCode.DIVIDE => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .NUMBER = a.NUMBER / b.NUMBER });
            },
            OpCode.NEGATE => {
                try unary_number_check(&vm);
                const number = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .NUMBER = -number.NUMBER });
            },
            OpCode.GREATER_THAN => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .BOOLEAN = a.NUMBER > b.NUMBER });
            },
            OpCode.LESS_THAN => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxConstant{ .BOOLEAN = a.NUMBER < b.NUMBER });
            },
            OpCode.EQUALS => {
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                var equal = true;
                if (@intFromEnum(a) != @intFromEnum(b)) {
                    equal = false;
                } else {
                    equal = switch (a) {
                        LoxType.NUMBER => a.NUMBER == b.NUMBER,
                        LoxType.BOOLEAN => a.BOOLEAN == b.BOOLEAN,
                        LoxType.NIL => true,
                        LoxType.OBJECT => switch (a.OBJECT.type) {
                            LoxObject.Type.STRING => std.mem.eql(u8, a.OBJECT.as_string().string, b.OBJECT.as_string().string),
                        },
                    };
                }
                if (a == .OBJECT) {
                    a.OBJECT.free(al);
                }
                if (b == .OBJECT) {
                    b.OBJECT.free(al);
                }

                try vm.stack.append(LoxConstant{ .BOOLEAN = equal });
            },
            OpCode.RETURN => {
                const constant = vm.stack.pop();
                if (constant == .OBJECT) {
                    defer constant.OBJECT.free(al);
                }
                const formatted_constant = try format_constant(al, constant);
                if (vm.stack.items.len != 0) {
                    return error.StackNotEmpty;
                }
                return formatted_constant;
            },
        }
    }
}
