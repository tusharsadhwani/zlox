const std = @import("std");
const compiler = @import("compiler.zig");
const LoxObject = compiler.LoxObject;
const LoxValue = compiler.LoxValue;

pub const HashTable = struct {
    const Entry = struct {
        hash: u32,
        key: []u8,
        // TODO: We never expose a null value to the users of the hash table.
        // Maybe a magic uncreatable LoxValue can be used internally
        // to denote the null state, making the api even cleaner.
        value: ?LoxValue,
    };

    al: std.mem.Allocator,
    entries: []?*Entry,
    capacity: u32,
    count: u32,

    pub fn init(al: std.mem.Allocator) !*HashTable {
        var table = try al.create(HashTable);
        table.al = al;
        table.capacity = 32;
        table.count = 0;
        try table.allocate_entries();
        return table;
    }

    fn allocate_entries(self: *HashTable) !void {
        self.entries = try self.al.alloc(?*Entry, self.capacity);
        for (0..self.entries.len) |idx| {
            self.entries[idx] = null;
        }
    }

    fn deallocate_entries(self: *HashTable, free_keys: bool) void {
        for (self.entries) |entry| {
            if (entry != null) {
                if (free_keys) {
                    self.al.free(entry.?.key);
                } else {}
                self.al.destroy(entry.?);
            }
        }
        self.al.free(self.entries);
    }

    pub fn deinit(self: *HashTable) void {
        self.deallocate_entries(true);
        self.al.destroy(self);
    }

    fn find_entry(self: *HashTable, key: []u8) !*Entry {
        const hash = std.hash.Fnv1a_32.hash(key);
        var idx = hash % self.capacity;

        while (true) {
            const entry = self.entries[idx];
            if (entry != null) {
                if (!std.mem.eql(u8, entry.?.key, key)) {
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
    pub fn find(self: *HashTable, key: []u8) !?LoxValue {
        const entry = try self.find_entry(key);
        if (entry.value == null) {
            return null;
        }
        return entry.value.?;
    }
    pub fn find_key(self: *HashTable, key: []u8) !?[]u8 {
        const entry = try self.find_entry(key);
        if (entry.value == null) {
            return null;
        }
        return entry.key;
    }

    // TODO: remove anyerror, a zig bug isn't letting me dd that right now
    // error: unable to resolve inferred error set
    fn insert_entry(self: *HashTable, entry: *Entry, value: LoxValue) anyerror!void {
        entry.value = value;
        self.count += 1;
        // If the table is too full, reallocate.
        if (@as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.capacity)) >= 0.75) {
            var new_hash_table = try HashTable.init(self.al);
            // TODO: this deallocate and reallocate is kinda wasteful.
            new_hash_table.deallocate_entries(true);
            new_hash_table.capacity = self.capacity * 2;
            try new_hash_table.allocate_entries();

            for (self.entries) |old_entry| {
                if (old_entry != null) {
                    try new_hash_table.insert(old_entry.?.key, old_entry.?.value.?);
                }
            }
            self.deallocate_entries(false);
            self.capacity = new_hash_table.capacity;
            self.entries = new_hash_table.entries;
            self.al.destroy(new_hash_table);
        }
    }
    pub fn insert(self: *HashTable, key: []u8, value: LoxValue) !void {
        try self.insert_entry(try self.find_entry(key), value);
    }

    // TODO: deletion and tombstones
};

test "HashTable one insert" {
    const al = std.testing.allocator;

    const table = try HashTable.init(al);
    defer table.deinit();

    const sample_string = "foobar";

    const key = try std.fmt.allocPrint(al, sample_string, .{});
    const entry = try table.find_entry(key);
    try table.insert_entry(entry, LoxValue{ .NUMBER = 42 });
    const retrieved_key = try table.find_entry(key);
    try std.testing.expectEqualStrings(sample_string, retrieved_key.key);
}

test "HashTable 23 inserts" {
    const al = std.testing.allocator;

    const table = try HashTable.init(al);
    defer table.deinit();
    const template = "foobar {d}";
    for (0..23) |index| {
        const inserted_string = try std.fmt.allocPrint(al, template, .{index});
        const retrieved_entry = try table.find_entry(inserted_string);
        try table.insert_entry(retrieved_entry, LoxValue{ .BOOLEAN = true });
        try std.testing.expectEqualStrings(inserted_string, retrieved_entry.key);
    }
}

test "HashTable 1000 inserts" {
    const al = std.testing.allocator;

    const table = try HashTable.init(al);
    defer table.deinit();
    const template = "foobar {d}";
    for (0..1000) |index| {
        const inserted_string = try std.fmt.allocPrint(al, template, .{index});
        try table.insert(inserted_string, LoxValue{ .BOOLEAN = true });
        const retrieved_key = try table.find_key(inserted_string);
        try std.testing.expectEqualStrings(inserted_string, retrieved_key.?);
    }
}
