const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const TokenType = tokenizer.TokenType;
const HashTable = @import("hashtable.zig").HashTable;

pub const LoxType = enum {
    NUMBER,
    BOOLEAN,
    NIL,
    OBJECT,
};
pub const LoxConstant = union(LoxType) {
    NUMBER: f32,
    BOOLEAN: bool,
    NIL: u0,
    OBJECT: *LoxObject,
};
pub const ConstantStack = std.ArrayList(LoxConstant);

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
        const entry = try self.strings.find_entry(string);
        if (entry.value != null) {
            // If we have seen this string, deallocate this one replace with the interned one.
            const existing_string = entry.key;
            self.al.free(string);
            return existing_string;
        }
        try self.strings.insert(string, LoxConstant{ .BOOLEAN = true });
        return string;
    }
};

pub const LoxString = struct {
    object: LoxObject,
    string: []u8,
};

pub const Chunk = struct {
    data: std.ArrayList(u8),
    constants: ConstantStack,
};

const Parser = struct {
    current: usize,
    tokens: []tokenizer.Token,
    source: []u8,
    chunk: *Chunk,
    parse_rules: ParseRules,
    ctx: *GlobalContext,
};
const ParseRules = std.AutoHashMap(TokenType, ParseRule);

fn create_chunk(al: std.mem.Allocator) !*Chunk {
    var chunk = try al.create(Chunk);
    chunk.data = std.ArrayList(u8).init(al);
    chunk.constants = ConstantStack.init(al);
    return chunk;
}

pub fn free_chunk(chunk: *Chunk) void {
    chunk.data.deinit();
    chunk.constants.deinit();
    chunk.data.allocator.destroy(chunk);
}

pub fn compile(ctx: *GlobalContext, tokens: []tokenizer.Token, source: []u8) !*Chunk {
    const chunk = try create_chunk(ctx.al);

    var parseRules = ParseRules.init(ctx.al);
    defer parseRules.deinit();

    try parseRules.put(
        TokenType.PLUS,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.TERM,
        },
    );
    try parseRules.put(
        TokenType.MINUS,
        ParseRule{
            .prefix = parse_unary,
            .infix = parse_binary,
            .precedence = Precedence.TERM,
        },
    );
    try parseRules.put(
        TokenType.STAR,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.FACTOR,
        },
    );
    try parseRules.put(
        TokenType.SLASH,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.FACTOR,
        },
    );
    try parseRules.put(
        TokenType.GREATER_THAN,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.COMPARISON,
        },
    );
    try parseRules.put(
        TokenType.LESS_THAN,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.COMPARISON,
        },
    );
    try parseRules.put(
        TokenType.EQUAL_EQUAL,
        ParseRule{
            .prefix = null,
            .infix = parse_binary,
            .precedence = Precedence.EQUALITY,
        },
    );
    try parseRules.put(
        TokenType.NUMBER,
        ParseRule{
            .prefix = parse_number,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.STRING,
        ParseRule{
            .prefix = parse_string,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.TRUE,
        ParseRule{
            .prefix = parse_boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.FALSE,
        ParseRule{
            .prefix = parse_boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.NIL,
        ParseRule{
            .prefix = parse_nil,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.EOF,
        ParseRule{
            .prefix = null,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    var parser = Parser{
        .current = 0,
        .tokens = tokens,
        .source = source,
        .chunk = chunk,
        .parse_rules = parseRules,
        .ctx = ctx,
    };

    try expression(&parser);
    try consume(&parser, TokenType.EOF);
    try emit_byte(&parser, @intFromEnum(OpCode.RETURN));
    return chunk;
}

const ParseFn = *const fn (*Parser) anyerror!void;

const Precedence = enum(u8) {
    NONE,
    ASSIGNMENT,
    EQUALITY,
    COMPARISON,
    TERM, // + -
    FACTOR, // * /
    UNARY, // ! -
};

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

fn peek(parser: *Parser) *tokenizer.Token {
    return &parser.tokens[parser.current];
}

fn advance(parser: *Parser) void {
    parser.current += 1;
}

fn previous_token(parser: *Parser) *tokenizer.Token {
    return &parser.tokens[parser.current - 1];
}

fn read_token(parser: *Parser) *tokenizer.Token {
    advance(parser);
    return previous_token(parser);
}

fn consume(parser: *Parser, token_type: TokenType) !void {
    if (peek(parser).type != token_type) {
        return error.UnexpectedToken;
    }
}

fn expression(parser: *Parser) !void {
    try parse_precedence(parser, Precedence.ASSIGNMENT);
}

fn parse_precedence(parser: *Parser, precedence: Precedence) !void {
    var token = read_token(parser);
    const prefix_rule = parser.parse_rules.get(token.type).?.prefix;
    if (prefix_rule == null) {
        return error.ExpressionExpected;
    }
    try prefix_rule.?(parser);

    while (true) {
        if (@intFromEnum(precedence) <= @intFromEnum(parser.parse_rules.get(peek(parser).type).?.precedence)) {
            token = read_token(parser);
            const infix_rule = parser.parse_rules.get(token.type).?.infix;
            if (infix_rule == null) {
                return error.ExpressionExpected;
            }
            try infix_rule.?(parser);
        } else {
            break;
        }
    }
}

fn parse_unary(parser: *Parser) !void {
    const operator = previous_token(parser).type;
    try parse_precedence(parser, @enumFromInt(@intFromEnum(parser.parse_rules.get(operator).?.precedence) + 1));
    try switch (operator) {
        TokenType.MINUS => emit_byte(parser, @intFromEnum(OpCode.NEGATE)),
        else => unreachable,
    };
}
fn parse_binary(parser: *Parser) !void {
    const operator = previous_token(parser).type;
    try parse_precedence(parser, @enumFromInt(@intFromEnum(parser.parse_rules.get(operator).?.precedence) + 1));
    try switch (operator) {
        TokenType.PLUS => emit_byte(parser, @intFromEnum(OpCode.ADD)),
        TokenType.MINUS => emit_byte(parser, @intFromEnum(OpCode.SUBTRACT)),
        TokenType.STAR => emit_byte(parser, @intFromEnum(OpCode.MULTIPLY)),
        TokenType.SLASH => emit_byte(parser, @intFromEnum(OpCode.DIVIDE)),
        TokenType.LESS_THAN => emit_byte(parser, @intFromEnum(OpCode.LESS_THAN)),
        TokenType.GREATER_THAN => emit_byte(parser, @intFromEnum(OpCode.GREATER_THAN)),
        TokenType.EQUAL_EQUAL => emit_byte(parser, @intFromEnum(OpCode.EQUALS)),
        else => unreachable,
    };
}
fn parse_number(parser: *Parser) !void {
    const num_token = previous_token(parser);
    const number = try std.fmt.parseFloat(
        std.meta.FieldType(LoxConstant, .NUMBER),
        parser.source[num_token.start .. num_token.start + num_token.len],
    );
    try emit_constant(parser, LoxConstant{ .NUMBER = number });
}
fn parse_string(parser: *Parser) !void {
    const string_token = previous_token(parser);
    // +1 and -1 to remove quotes.
    // TODO This doesn't handle any un-escaping
    const string_slice = try parser.ctx.al.dupe(u8, parser.source[string_token.start + 1 .. string_token.start + string_token.len - 1]);
    const string_object = try LoxObject.allocate_string(parser.ctx, string_slice);
    try emit_constant(parser, LoxConstant{ .OBJECT = string_object });
}
fn parse_boolean(parser: *Parser) !void {
    const num_token = previous_token(parser);
    try emit_constant(parser, LoxConstant{
        .BOOLEAN = if (num_token.type == TokenType.TRUE) true else false,
    });
}
fn parse_nil(parser: *Parser) !void {
    try emit_constant(parser, LoxConstant{ .NIL = 0 });
}

pub const OpCode = enum(u8) {
    CONSTANT,
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    NEGATE,
    LESS_THAN,
    GREATER_THAN,
    EQUALS,
    RETURN,
};

fn emit_byte(parser: *Parser, byte: u8) !void {
    try parser.chunk.data.append(byte);
}
fn emit_bytes(parser: *Parser, byte1: u8, byte2: u8) !void {
    const data = &parser.chunk.data;
    try parser.chunk.data.append(byte1);
    try data.append(byte2);
}

fn add_constant(parser: *Parser, constant: LoxConstant) !u8 {
    const constants = &parser.chunk.constants;
    try constants.append(constant);
    if (constants.items.len >= 256) {
        return error.TooManyConstants;
    }
    return @intCast(constants.items.len - 1);
}

fn emit_constant(parser: *Parser, value: LoxConstant) !void {
    const constant_index = try add_constant(parser, value);
    try emit_bytes(parser, @intFromEnum(OpCode.CONSTANT), constant_index);
}
