const std = @import("std");

const GlobalContext = @import("context.zig").GlobalContext;
const parse = @import("parse.zig");
const compiler = @import("compiler.zig");
const OpCode = compiler.OpCode;
const HashTable = @import("hashtable.zig").HashTable;
const types = @import("types.zig");
const LoxValue = types.LoxValue;
const LoxType = types.LoxType;
const LoxObject = types.LoxObject;
const LoxString = types.LoxString;

const VM = struct {
    ctx: *GlobalContext,

    chunk: *parse.Chunk,
    stack: parse.ConstantStack,
    globals: *HashTable,
    ip: [*]u8,

    fn peek(self: *VM, index: usize) LoxValue {
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
fn binary_check(vm: *VM) !void {
    const b = vm.peek(0);
    const a = vm.peek(1);
    if (@intFromEnum(a) != @intFromEnum(b)) {
        return error.RuntimeError;
    }
}

pub fn format_constant(al: std.mem.Allocator, constant: LoxValue) ![]u8 {
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

fn concatenate_strings(vm: *VM, a: *LoxString, b: *LoxString) !*LoxObject {
    const concatenated_string = try std.mem.concat(vm.ctx.al, u8, &.{ a.string, b.string });
    return try LoxObject.allocate_string(vm.ctx, concatenated_string);
}

pub fn interpret(ctx: *GlobalContext, chunk: *parse.Chunk, writer: std.io.AnyWriter) !void {
    var vm = VM{
        .chunk = chunk,
        .stack = parse.ConstantStack.init(ctx.al),
        .globals = try HashTable.init(ctx.al, .{}),
        .ip = chunk.data.items.ptr,
        .ctx = ctx,
    };
    defer vm.stack.deinit();
    defer vm.globals.deinit();

    while (true) {
        const x = next_byte(&vm);
        const opcode: OpCode = @enumFromInt(x);
        switch (opcode) {
            OpCode.POP => {
                _ = vm.stack.pop();
            },
            OpCode.CONSTANT => {
                const constant_index = next_byte(&vm);
                try vm.stack.append(vm.chunk.constants.items[constant_index]);
            },
            // OpCode.DEFINE_GLOBAL => {
            //     const global_index = next_byte(&vm);
            //     const global_name = vm.chunk.varnames.items[global_index];
            //     // TODO: don't pop before insert passes, this will make the GC mad
            //     try vm.globals.insert(global_name, vm.stack.pop());
            // },
            OpCode.ADD => {
                try binary_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                const result = switch (a) {
                    LoxType.NUMBER => LoxValue{ .NUMBER = a.NUMBER + b.NUMBER },
                    LoxType.OBJECT => switch (a.OBJECT.type) {
                        LoxObject.Type.STRING => LoxValue{
                            .OBJECT = try concatenate_strings(&vm, a.OBJECT.as_string(), b.OBJECT.as_string()),
                        },
                    },
                    else => return error.RuntimeError,
                };
                try vm.stack.append(result);
            },
            OpCode.SUBTRACT => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxValue{ .NUMBER = a.NUMBER - b.NUMBER });
            },
            OpCode.MULTIPLY => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxValue{ .NUMBER = a.NUMBER * b.NUMBER });
            },
            OpCode.DIVIDE => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxValue{ .NUMBER = a.NUMBER / b.NUMBER });
            },
            OpCode.NEGATE => {
                try unary_number_check(&vm);
                const number = vm.stack.pop();
                try vm.stack.append(LoxValue{ .NUMBER = -number.NUMBER });
            },
            OpCode.GREATER_THAN => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxValue{ .BOOLEAN = a.NUMBER > b.NUMBER });
            },
            OpCode.LESS_THAN => {
                try binary_number_check(&vm);
                const b = vm.stack.pop();
                const a = vm.stack.pop();
                try vm.stack.append(LoxValue{ .BOOLEAN = a.NUMBER < b.NUMBER });
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
                            LoxObject.Type.STRING => a.OBJECT.as_string().string.ptr == b.OBJECT.as_string().string.ptr,
                        },
                    };
                }
                try vm.stack.append(LoxValue{ .BOOLEAN = equal });
            },
            OpCode.PRINT => {
                const constant = vm.stack.pop();
                if (vm.stack.items.len != 0) {
                    return error.StackNotEmpty;
                }
                const formatted_constant = try format_constant(vm.ctx.al, constant);
                defer vm.ctx.al.free(formatted_constant);
                _ = try writer.write(formatted_constant);
                _ = try writer.writeByte('\n');
            },
            OpCode.EXIT => {
                break;
            },
        }
    }
}
