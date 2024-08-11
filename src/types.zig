const std = @import("std");

const GlobalContext = @import("context.zig").GlobalContext;

pub const LoxType = enum {
    NUMBER,
    BOOLEAN,
    NIL,
    OBJECT,
};
pub const LoxValue = union(LoxType) {
    NUMBER: f32,
    BOOLEAN: bool,
    NIL: u0,
    OBJECT: *LoxObject,
};

pub const LoxObject = struct {
    type: Type,

    pub const Type = enum { STRING };

    pub fn allocate(ctx: *GlobalContext, comptime T: type, object_type: Type) !*LoxObject {
        const ptr = try ctx.al.create(T);
        ptr.object = LoxObject{ .type = object_type };
        try ctx.add_object(&ptr.object);
        return &ptr.object;
    }

    pub fn allocate_string(ctx: *GlobalContext, string: []u8) !*LoxObject {
        const ptr = try ctx.al.create(LoxString);
        ptr.object = LoxObject{ .type = .STRING };
        ptr.string = try ctx.intern_string(string);
        try ctx.add_object(&ptr.object);
        return &ptr.object;
    }

    pub fn free(self: *LoxObject, al: std.mem.Allocator) void {
        switch (self.type) {
            .STRING => {
                // Strings are interned, no need to free `.string` here.
                al.destroy(self.as_string());
            },
        }
    }

    pub fn as_string(self: *LoxObject) *LoxString {
        return @alignCast(@fieldParentPtr("object", self));
    }
};

pub const LoxString = struct {
    object: LoxObject,
    string: []u8,
};
