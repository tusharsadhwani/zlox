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
        value: ?LoxConstant,
    };

    al: std.mem.Allocator,
    entries: []?*Entry,
    length: u32,

    pub fn init(al: std.mem.Allocator) !*HashTable {
        var table = try al.create(HashTable);
        table.al = al;
        table.length = 32;
        table.entries = try al.alloc(?*Entry, table.length);
        for (0..table.entries.len) |idx| {
            table.entries[idx] = null;
        }
        return table;
    }

    pub fn deinit(self: *HashTable) void {
        for (self.entries) |entry| {
            if (entry != null) {
                self.al.destroy(entry.?);
            }
        }
        self.al.free(self.entries);
        self.al.destroy(self);
    }

    pub fn find_entry(self: *HashTable, key: *LoxString) !*Entry {
        const hash = std.hash.Fnv1a_32.hash(key.string);
        var idx = hash % self.length;

        while (true) {
            const entry = self.entries[idx];
            if (entry != null) {
                if (!std.mem.eql(u8, entry.?.key.string, key.string)) {
                    // We have a hash collision. Probe for empty spot linearly.
                    idx += 1;
                    continue;
                }
                return entry.?;
            }
            const new_entry = try self.al.create(Entry);
            new_entry.hash = hash;
            new_entry.key = key;
            new_entry.value = null;
            self.entries[idx] = new_entry;
            return new_entry;
        }
    }

    pub fn insert(self: *HashTable, key: *LoxString, value: LoxConstant) !void {
        var entry = try self.find_entry(key);
        entry.value = value;
    }
    // TODO: deletion and tombstones
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
    const retrieved_key = try table.find_entry(key);
    try std.testing.expectEqualStrings(sample_string, retrieved_key.key.string);
}

test "HashTable 23 inserts" {
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
    for (0..23) |index| {
        const inserted_string = try std.fmt.allocPrint(al, template, .{index});

        const key = try al.create(LoxString);
        key.object = LoxObject{ .type = .STRING };
        key.string = inserted_string;

        try table.insert(key, LoxConstant{ .NUMBER = 42 });
        const retrieved_key = try table.find_entry(key);
        try std.testing.expectEqualStrings(inserted_string, retrieved_key.key.string);
    }
}
