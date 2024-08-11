const std = @import("std");

const HashTable = @import("hashtable.zig").HashTable;
const types = @import("types.zig");
const LoxValue = types.LoxValue;
const LoxObject = types.LoxObject;

pub const GlobalContext = struct {
    al: std.mem.Allocator,
    objects: std.ArrayList(*LoxObject),
    strings: *HashTable,

    pub fn init(al: std.mem.Allocator) !*GlobalContext {
        var store = try al.create(GlobalContext);
        store.al = al;
        store.objects = std.ArrayList(*LoxObject).init(al);
        store.strings = try HashTable.init(al);
        return store;
    }

    pub fn free(self: *GlobalContext) void {
        for (self.objects.items) |object| {
            object.free(self.al);
        }
        self.objects.deinit();
        self.strings.deinit();
        self.al.destroy(self);
    }

    pub fn add_object(self: *GlobalContext, object: *LoxObject) !void {
        try self.objects.append(object);
    }

    pub fn intern_string(self: *GlobalContext, string: []u8) ![]u8 {
        const interned_string = try self.strings.find_key(string);
        if (interned_string != null) {
            // If we have seen this string, deallocate this one replace with the interned one.
            self.al.free(string);
            return interned_string.?;
        }
        try self.strings.insert(string, LoxValue{ .BOOLEAN = true });
        return string;
    }
};
