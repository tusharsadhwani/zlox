const std = @import("std");
const compiler = @import("compiler.zig");
const LoxObject = compiler.LoxObject;
const LoxString = compiler.LoxString;
const LoxConstant = compiler.LoxConstant;

pub const HashTable = struct {
    const Entry = struct {
        hash: u32,
        // The table doesn't own the key.
        key: *LoxString,
        value: LoxConstant,
    };

    al: std.mem.Allocator,
    entries: []?Entry,
    length: u32,

    pub fn init(al: std.mem.Allocator) !*HashTable {
        var table = try al.create(HashTable);
        table.al = al;
        table.length = 32;
        table.entries = try al.alloc(?Entry, table.length);
        for (0..table.entries.len) |idx| {
            table.entries[idx] = null;
        }
        return table;
    }

    pub fn deinit(self: *HashTable) void {
        self.al.free(self.entries);
        self.al.destroy(self);
    }

    pub fn insert(self: *HashTable, key: *LoxString, value: LoxConstant) !void {
        const hash = std.hash.Fnv1a_32.hash(key.string);
        const idx = hash % self.length;
        if (self.entries[idx] != null) {
            // TODO: collision detection
            return error.HashCollision;
        }
        self.entries[idx] = Entry{
            .hash = hash,
            .key = key,
            .value = value,
        };
    }

    pub fn index(self: *HashTable, key: *LoxString) ?u32 {
        const hash = std.hash.Fnv1a_32.hash(key.string);
        const idx = hash % self.length;
        const entry = self.entries[idx];
        if (entry == null) {
            return null;
        }
        // TODO: on collision, we need to do linear probling.
        if (!std.mem.eql(u8, key.string, entry.?.key.string)) {
            return null;
        }
        return idx;
    }
};

test "HashTable one insert" {
    const al = std.testing.allocator;

    const table = try HashTable.init(al);
    defer table.deinit();

    const sample_string = "foobar";

    const key = try al.create(LoxString);
    // Since strings are not interned here, we need to manually free the LoxString's
    defer al.destroy(key);
    defer al.free(key.string);

    key.object = LoxObject{ .type = .STRING };
    key.string = try std.fmt.allocPrint(al, sample_string, .{});

    try table.insert(key, LoxConstant{ .NUMBER = 42 });
    const key_index = table.index(key).?;
    const retrieved_key = table.entries[@intCast(key_index)].?;
    try std.testing.expectEqualStrings(sample_string, retrieved_key.key.string);
}

test "HashTable 10 inserts" {
    const al = std.testing.allocator;

    const table = try HashTable.init(al);
    defer table.deinit();
    // Since strings are not interned here, we need to manually free the LoxString's
    defer for (table.entries) |entry| {
        if (entry != null) {
            al.free(entry.?.key.string);
            al.destroy(entry.?.key);
        }
    };

    const template = "foobar {d}";
    for (0..10) |index| {
        const inserted_string = try std.fmt.allocPrint(al, template, .{index});

        const key = try al.create(LoxString);
        key.object = LoxObject{ .type = .STRING };
        key.string = inserted_string;

        try table.insert(key, LoxConstant{ .NUMBER = 42 });
        const key_index = table.index(key).?;
        const retrieved_key = table.entries[@intCast(key_index)].?;
        try std.testing.expectEqualStrings(inserted_string, retrieved_key.key.string);
    }
}
