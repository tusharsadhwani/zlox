const std = @import("std");

const GlobalContext = @import("context.zig").GlobalContext;
const tokenizer = @import("tokenizer.zig");
const TokenType = tokenizer.TokenType;
const compiler = @import("compiler.zig");
const OpCode = compiler.OpCode;
const types = @import("types.zig");
const LoxValue = types.LoxValue;
const LoxType = types.LoxType;
const LoxObject = types.LoxObject;
const LoxString = types.LoxString;

pub const ConstantStack = std.ArrayList(LoxValue);

pub const Chunk = struct {
    al: std.mem.Allocator,
    data: std.ArrayList(u8),
    constants: ConstantStack,

    pub fn create(al: std.mem.Allocator) !*Chunk {
        var chunk = try al.create(Chunk);
        chunk.al = al;
        chunk.data = std.ArrayList(u8).init(al);
        chunk.constants = ConstantStack.init(al);
        return chunk;
    }

    pub fn free(self: *Chunk) void {
        self.data.deinit();
        self.constants.deinit();
        self.al.destroy(self);
    }
};

const Precedence = enum(u8) {
    NONE,
    ASSIGNMENT,
    EQUALITY,
    COMPARISON,
    TERM, // + -
    FACTOR, // * /
    UNARY, // ! -
};

pub const Parser = struct {
    ctx: *GlobalContext,
    current: usize,
    tokens: []tokenizer.Token,
    source: []u8,
    chunk: *Chunk,
    parse_rules: ParseRules,

    fn parse_unary(self: *Parser) !void {
        const operator = previous_token(self).type;
        try parse_precedence(self, @enumFromInt(@intFromEnum(self.parse_rules.get(operator).?.precedence) + 1));
        try switch (operator) {
            TokenType.MINUS => emit_byte(self, @intFromEnum(OpCode.NEGATE)),
            else => unreachable,
        };
    }
    fn parse_binary(self: *Parser) !void {
        const operator = previous_token(self).type;
        try parse_precedence(self, @enumFromInt(@intFromEnum(self.parse_rules.get(operator).?.precedence) + 1));
        try switch (operator) {
            TokenType.PLUS => emit_byte(self, @intFromEnum(OpCode.ADD)),
            TokenType.MINUS => emit_byte(self, @intFromEnum(OpCode.SUBTRACT)),
            TokenType.STAR => emit_byte(self, @intFromEnum(OpCode.MULTIPLY)),
            TokenType.SLASH => emit_byte(self, @intFromEnum(OpCode.DIVIDE)),
            TokenType.LESS_THAN => emit_byte(self, @intFromEnum(OpCode.LESS_THAN)),
            TokenType.GREATER_THAN => emit_byte(self, @intFromEnum(OpCode.GREATER_THAN)),
            TokenType.EQUAL_EQUAL => emit_byte(self, @intFromEnum(OpCode.EQUALS)),
            else => unreachable,
        };
    }
    fn parse_number(self: *Parser) !void {
        const num_token = previous_token(self);
        const number = try std.fmt.parseFloat(
            std.meta.FieldType(LoxValue, .NUMBER),
            self.source[num_token.start .. num_token.start + num_token.len],
        );
        try emit_constant(self, LoxValue{ .NUMBER = number });
    }
    fn parse_string(self: *Parser) !void {
        const string_token = previous_token(self);
        // +1 and -1 to remove quotes.
        // TODO This doesn't handle any un-escaping
        const string_slice = try self.ctx.al.dupe(u8, self.source[string_token.start + 1 .. string_token.start + string_token.len - 1]);
        const string_object = try LoxObject.allocate_string(self.ctx, string_slice);
        try emit_constant(self, LoxValue{ .OBJECT = string_object });
    }
    fn parse_boolean(self: *Parser) !void {
        const num_token = previous_token(self);
        try emit_constant(self, LoxValue{
            .BOOLEAN = if (num_token.type == TokenType.TRUE) true else false,
        });
    }
    fn parse_nil(self: *Parser) !void {
        try emit_constant(self, LoxValue{ .NIL = 0 });
    }

    fn peek(self: *Parser) *tokenizer.Token {
        return &self.tokens[self.current];
    }

    fn advance(self: *Parser) void {
        self.current += 1;
    }

    fn previous_token(self: *Parser) *tokenizer.Token {
        return &self.tokens[self.current - 1];
    }

    fn read_token(self: *Parser) *tokenizer.Token {
        advance(self);
        return previous_token(self);
    }

    pub fn consume(self: *Parser, token_type: TokenType) !void {
        if (peek(self).type != token_type) {
            return error.UnexpectedToken;
        }
    }

    pub fn expression(self: *Parser) !void {
        try parse_precedence(self, Precedence.ASSIGNMENT);
    }

    fn parse_precedence(self: *Parser, precedence: Precedence) !void {
        var token = read_token(self);
        const prefix_rule = self.parse_rules.get(token.type).?.prefix;
        if (prefix_rule == null) {
            return error.ExpressionExpected;
        }
        try prefix_rule.?(self);

        while (true) {
            if (@intFromEnum(precedence) <= @intFromEnum(self.parse_rules.get(peek(self).type).?.precedence)) {
                token = read_token(self);
                const infix_rule = self.parse_rules.get(token.type).?.infix;
                if (infix_rule == null) {
                    return error.ExpressionExpected;
                }
                try infix_rule.?(self);
            } else {
                break;
            }
        }
    }

    // TODO: unpub
    pub fn emit_byte(self: *Parser, byte: u8) !void {
        try self.chunk.data.append(byte);
    }
    fn emit_bytes(self: *Parser, byte1: u8, byte2: u8) !void {
        const data = &self.chunk.data;
        try self.chunk.data.append(byte1);
        try data.append(byte2);
    }

    fn add_constant(self: *Parser, constant: LoxValue) !u8 {
        const constants = &self.chunk.constants;
        try constants.append(constant);
        if (constants.items.len >= 256) {
            return error.TooManyConstants;
        }
        return @intCast(constants.items.len - 1);
    }

    fn emit_constant(self: *Parser, value: LoxValue) !void {
        const constant_index = try add_constant(self, value);
        try emit_bytes(self, @intFromEnum(OpCode.CONSTANT), constant_index);
    }
};

const ParseFn = *const fn (*Parser) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};
pub const ParseRules = std.AutoHashMap(TokenType, ParseRule);

const ParseRuleTuple = struct { TokenType, ParseRule };
pub const PARSE_RULES: [13]ParseRuleTuple = .{
    .{
        TokenType.PLUS,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.TERM,
        },
    },
    .{
        TokenType.MINUS,
        ParseRule{
            .prefix = Parser.parse_unary,
            .infix = Parser.parse_binary,
            .precedence = Precedence.TERM,
        },
    },
    .{
        TokenType.STAR,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.FACTOR,
        },
    },
    .{
        TokenType.SLASH,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.FACTOR,
        },
    },
    .{
        TokenType.GREATER_THAN,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.COMPARISON,
        },
    },
    .{
        TokenType.LESS_THAN,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.COMPARISON,
        },
    },
    .{
        TokenType.EQUAL_EQUAL,
        ParseRule{
            .prefix = null,
            .infix = Parser.parse_binary,
            .precedence = Precedence.EQUALITY,
        },
    },
    .{
        TokenType.NUMBER,
        ParseRule{
            .prefix = Parser.parse_number,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.STRING,
        ParseRule{
            .prefix = Parser.parse_string,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.TRUE,
        ParseRule{
            .prefix = Parser.parse_boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.FALSE,
        ParseRule{
            .prefix = Parser.parse_boolean,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.NIL,
        ParseRule{
            .prefix = Parser.parse_nil,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.EOF,
        ParseRule{
            .prefix = null,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
};
