const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const TokenType = tokenizer.TokenType;

pub const LoxType = enum(u8) {
    NUMBER,
    BOOLEAN,
    NIL,
};
pub const LoxConstant = union(LoxType) {
    NUMBER: f32,
    BOOLEAN: bool,
    NIL: u0,
};
pub const ConstantStack = std.ArrayList(LoxConstant);

pub const Chunk = struct {
    data: std.ArrayList(u8),
    constants: ConstantStack,
};

const Parser = struct { current: usize, tokens: []tokenizer.Token, source: []u8, chunk: *Chunk, parse_rules: ParseRules };
const ParseRules = std.AutoHashMap(TokenType, ParseRule);

fn create_chunk(al: std.mem.Allocator) !*Chunk {
    var chunk = try al.create(Chunk);
    chunk.data = std.ArrayList(u8).init(al);
    chunk.constants = ConstantStack.init(al);
    return chunk;
}

pub fn free_chunk(chunk: *Chunk) void {
    chunk.data.clearAndFree();
    chunk.constants.clearAndFree();
    chunk.data.allocator.destroy(chunk);
}

pub fn compile(al: std.mem.Allocator, tokens: []tokenizer.Token, source: []u8) !*Chunk {
    const chunk = try create_chunk(al);

    var parseRules = ParseRules.init(al);
    defer parseRules.deinit();

    try parseRules.put(
        TokenType.PLUS,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.TERM,
        },
    );
    try parseRules.put(
        TokenType.MINUS,
        ParseRule{
            .prefix = unary,
            .infix = binary,
            .precedence = Precedence.TERM,
        },
    );
    try parseRules.put(
        TokenType.STAR,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.FACTOR,
        },
    );
    try parseRules.put(
        TokenType.SLASH,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.FACTOR,
        },
    );
    try parseRules.put(
        TokenType.GREATER_THAN,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.COMPARISON,
        },
    );
    try parseRules.put(
        TokenType.LESS_THAN,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.COMPARISON,
        },
    );
    try parseRules.put(
        TokenType.EQUAL_EQUAL,
        ParseRule{
            .prefix = null,
            .infix = binary,
            .precedence = Precedence.EQUALITY,
        },
    );
    try parseRules.put(
        TokenType.NUMBER,
        ParseRule{
            .prefix = number,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.TRUE,
        ParseRule{
            .prefix = boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.FALSE,
        ParseRule{
            .prefix = boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    );
    try parseRules.put(
        TokenType.NIL,
        ParseRule{
            .prefix = nil,
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

fn unary(parser: *Parser) !void {
    const operator = previous_token(parser).type;
    try parse_precedence(parser, @enumFromInt(@intFromEnum(parser.parse_rules.get(operator).?.precedence) + 1));
    try switch (operator) {
        TokenType.MINUS => emit_byte(parser, @intFromEnum(OpCode.NEGATE)),
        else => unreachable,
    };
}
fn binary(parser: *Parser) !void {
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
fn number(parser: *Parser) !void {
    const num_token = previous_token(parser);
    const num = try std.fmt.parseFloat(
        std.meta.FieldType(LoxConstant, .NUMBER),
        parser.source[num_token.start .. num_token.start + num_token.len],
    );
    try emit_constant(parser, LoxConstant{ .NUMBER = num });
}
fn boolean(parser: *Parser) !void {
    const num_token = previous_token(parser);
    try emit_constant(parser, LoxConstant{
        .BOOLEAN = if (num_token.type == TokenType.TRUE) true else false,
    });
}
fn nil(parser: *Parser) !void {
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
