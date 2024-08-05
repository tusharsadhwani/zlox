const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const TokenType = tokenizer.TokenType;

pub const Chunk = struct {
    data: std.ArrayList(u8),
    constants: std.ArrayList(f32),
};

const Parser = struct { current: usize, tokens: []tokenizer.Token, source: []u8, chunk: *Chunk, parse_rules: ParseRules };
const ParseRules = std.AutoHashMap(TokenType, ParseRule);

fn createChunk(al: std.mem.Allocator) !*Chunk {
    var chunk = try al.create(Chunk);
    chunk.data = std.ArrayList(u8).init(al);
    chunk.constants = std.ArrayList(f32).init(al);
    return chunk;
}

pub fn freeChunk(chunk: *Chunk) void {
    chunk.data.clearAndFree();
    chunk.constants.clearAndFree();
}

pub fn compile(al: std.mem.Allocator, tokens: []tokenizer.Token, source: []u8) !*Chunk {
    const chunk = try createChunk(al);

    var parseRules = ParseRules.init(al);
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
        TokenType.NUMBER,
        ParseRule{
            .prefix = number,
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
        else => unreachable,
    };
}
fn number(parser: *Parser) !void {
    const num_token = previous_token(parser);
    const num = try std.fmt.parseFloat(
        f32,
        parser.source[num_token.start .. num_token.start + num_token.len],
    );
    try emit_constant(parser, num);
}

pub const OpCode = enum(u8) {
    CONSTANT,
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    NEGATE,
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

fn add_constant(parser: *Parser, constant: f32) !u8 {
    const constants = &parser.chunk.constants;
    try constants.append(constant);
    if (constants.items.len >= 256) {
        return error.TooManyConstants;
    }
    return @intCast(constants.items.len - 1);
}

fn emit_constant(parser: *Parser, value: f32) !void {
    const constant_index = try add_constant(parser, value);
    try emit_bytes(parser, @intFromEnum(OpCode.CONSTANT), constant_index);
}
