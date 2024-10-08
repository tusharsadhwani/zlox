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

pub const VM = struct {
    ctx: *GlobalContext,
    chunk: *parse.Chunk,
    stack: parse.ConstantStack,
    globals: *HashTable,
    ip: [*]u8,

    pub fn create(ctx: *GlobalContext, chunk: *parse.Chunk) !*VM {
        const vm = try ctx.al.create(VM);
        vm.ctx = ctx;
        vm.chunk = chunk;
        vm.stack = parse.ConstantStack.init(ctx.al);
        vm.globals = try HashTable.init(ctx.al, .{ .keys_owned = false });
        vm.ip = chunk.data.items.ptr;
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
        self.stack.deinit();
        self.ctx.al.destroy(self);
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

    fn peek(self: *VM, index: usize) LoxValue {
        return self.stack.items[self.stack.items.len - 1 - index];
    }

    fn next_byte(self: *VM) u8 {
        const byte = self.ip[0];
        self.ip += 1;
        return byte;
    }

    fn unary_number_check(self: *VM) !void {
        if (self.peek(0) != .NUMBER) {
            return error.RuntimeError;
        }
    }
    fn binary_number_check(self: *VM) !void {
        if (self.peek(0) != .NUMBER or self.peek(1) != .NUMBER) {
            return error.RuntimeError;
        }
    }
    fn binary_check(self: *VM) !void {
        const b = self.peek(0);
        const a = self.peek(1);
        if (@intFromEnum(a) != @intFromEnum(b)) {
            return error.RuntimeError;
        }
    }

    fn concatenate_strings(self: *VM, a: *LoxString, b: *LoxString) !*LoxObject {
        const concatenated_string = try std.mem.concat(self.ctx.al, u8, &.{ a.string, b.string });
        return try LoxObject.allocate_string(self.ctx, concatenated_string);
    }

    pub fn interpret(self: *VM, writer: std.io.AnyWriter) !void {
        while (true) {
            const x = self.next_byte();
            const opcode: OpCode = @enumFromInt(x);
            switch (opcode) {
                OpCode.POP => {
                    _ = self.stack.pop();
                },
                OpCode.GET_CONST => {
                    const constant_index = self.next_byte();
                    try self.stack.append(self.chunk.constants.items[constant_index]);
                },
                OpCode.ADD => {
                    try self.binary_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    const result = switch (a) {
                        LoxType.NUMBER => LoxValue{ .NUMBER = a.NUMBER + b.NUMBER },
                        LoxType.OBJECT => switch (a.OBJECT.type) {
                            LoxObject.Type.STRING => LoxValue{
                                .OBJECT = try self.concatenate_strings(a.OBJECT.as_string(), b.OBJECT.as_string()),
                            },
                        },
                        else => return error.RuntimeError,
                    };
                    try self.stack.append(result);
                },
                OpCode.SUBTRACT => {
                    try self.binary_number_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(LoxValue{ .NUMBER = a.NUMBER - b.NUMBER });
                },
                OpCode.MULTIPLY => {
                    try self.binary_number_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(LoxValue{ .NUMBER = a.NUMBER * b.NUMBER });
                },
                OpCode.DIVIDE => {
                    try self.binary_number_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(LoxValue{ .NUMBER = a.NUMBER / b.NUMBER });
                },
                OpCode.NEGATE => {
                    try self.unary_number_check();
                    const number = self.stack.pop();
                    try self.stack.append(LoxValue{ .NUMBER = -number.NUMBER });
                },
                OpCode.GREATER_THAN => {
                    try self.binary_number_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(LoxValue{ .BOOLEAN = a.NUMBER > b.NUMBER });
                },
                OpCode.LESS_THAN => {
                    try self.binary_number_check();
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(LoxValue{ .BOOLEAN = a.NUMBER < b.NUMBER });
                },
                OpCode.EQUALS => {
                    const b = self.stack.pop();
                    const a = self.stack.pop();
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
                    try self.stack.append(LoxValue{ .BOOLEAN = equal });
                },
                OpCode.PRINT => {
                    const constant = self.stack.pop();
                    const formatted_constant = try format_constant(self.ctx.al, constant);
                    defer self.ctx.al.free(formatted_constant);
                    _ = try writer.write(formatted_constant);
                    _ = try writer.writeByte('\n');
                },
                OpCode.DECLARE_GLOBAL => {
                    const global_index = self.next_byte();
                    const global_name = self.chunk.varnames.items[global_index];
                    try self.globals.insert(global_name, self.stack.getLast());
                    _ = self.stack.pop();
                },
                OpCode.SET_GLOBAL => {
                    const global_index = self.next_byte();
                    const global_name = self.chunk.varnames.items[global_index];
                    if (!try self.globals.has_key(global_name)) {
                        return error.UndeclaredVariable;
                    }
                    try self.globals.insert(global_name, self.stack.getLast());
                    // No popping, assignments return the assigned value.
                },
                OpCode.GET_GLOBAL => {
                    const global_index = self.next_byte();
                    const global_name = self.chunk.varnames.items[global_index];
                    const _value = try self.globals.find(global_name);
                    if (_value) |value| {
                        try self.stack.append(value);
                    } else {
                        return error.UndeclaredVariable;
                    }
                },
                OpCode.SET_LOCAL => {
                    const stack_top = self.stack.items.len - 1;
                    const local_index = self.next_byte();
                    self.stack.items[local_index] = self.stack.items[stack_top];
                },
                OpCode.GET_LOCAL => {
                    const local_index = self.next_byte();
                    const local = self.stack.items[@intCast(local_index)];
                    try self.stack.append(local);
                },
                OpCode.EXIT => {
                    if (self.stack.items.len != 0) {
                        if (self.ctx.debug) {
                            std.debug.print("------- Stack ------\n", .{});
                            for (self.stack.items) |item| {
                                std.debug.print("{}\n", .{item});
                            }
                            std.debug.print("----- End Stack ----\n", .{});
                        }
                        return error.StackNotEmpty;
                    }
                    break;
                },
            }
        }
    }
};
