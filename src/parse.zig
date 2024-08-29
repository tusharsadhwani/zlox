const std = @import("std");

const GlobalContext = @import("context.zig").GlobalContext;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
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
    varnames: std.ArrayList([]u8),

    pub fn create(al: std.mem.Allocator) !*Chunk {
        var chunk = try al.create(Chunk);
        chunk.al = al;
        chunk.data = std.ArrayList(u8).init(al);
        chunk.constants = ConstantStack.init(al);
        chunk.varnames = std.ArrayList([]u8).init(al);
        return chunk;
    }

    pub fn free(self: *Chunk) void {
        self.data.deinit();
        self.constants.deinit();
        self.varnames.deinit();
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
    const Local = struct {
        identifier: []u8,
        scope_depth: u8,
    };

    ctx: *GlobalContext,
    current: usize,
    tokens: []tokenizer.Token,
    source: []u8,
    chunk: *Chunk,
    locals: std.ArrayList(Local),
    scope_depth: u8,
    parse_rules: ParseRules,

    pub fn init(ctx: *GlobalContext, source: []u8, tokens: []tokenizer.Token, chunk: *Chunk, parse_rules: ParseRules) Parser {
        return Parser{
            .current = 0,
            .tokens = tokens,
            .source = source,
            .chunk = chunk,
            .locals = std.ArrayList(Local).init(ctx.al),
            .scope_depth = 0,
            .parse_rules = parse_rules,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.locals.deinit();
    }

    pub fn peek(self: *Parser) *tokenizer.Token {
        // TODO: can easily go out of bounds
        return &self.tokens[self.current];
    }

    fn advance(self: *Parser) void {
        self.current += 1;
    }

    pub fn match(self: *Parser, token_type: TokenType) bool {
        if (self.peek().type == token_type) {
            self.advance();
            return true;
        }
        return false;
    }

    fn previous_token(self: *Parser) *tokenizer.Token {
        return &self.tokens[self.current - 1];
    }

    fn read_token(self: *Parser) *tokenizer.Token {
        self.advance();
        return self.previous_token();
    }

    pub fn consume(self: *Parser, token_type: TokenType) !void {
        if (self.peek().type != token_type) {
            return error.UnexpectedToken;
        }
        self.advance();
    }

    fn parse_precedence(self: *Parser, precedence: Precedence) !void {
        var token = self.read_token();
        const parse_rule = self.parse_rules.get(token.type) orelse return error.InvalidSyntax;
        const prefix_rule = parse_rule.prefix orelse return error.ExpressionExpected;
        // TODO: maybe `can_assign` can be stored in `Parser` instead of passing everywhere
        const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.ASSIGNMENT);
        try prefix_rule(self, can_assign);

        if (!can_assign and self.match(TokenType.EQUAL)) {
            return error.InvalidAssignmentTarget;
        }

        while (true) {
            const next_rule = self.parse_rules.get(self.peek().type) orelse return error.InvalidSyntax;
            const next_precedence = next_rule.precedence;
            if (@intFromEnum(precedence) > @intFromEnum(next_precedence)) {
                break;
            }
            token = self.read_token();
            const next_parse_rule = self.parse_rules.get(token.type) orelse return error.InvalidSyntax;
            const infix_rule = next_parse_rule.infix orelse return error.ExpressionExpected;
            try infix_rule(self, can_assign);
        }
    }

    pub fn parse_block(self: *Parser) !void {
        self.scope_depth += 1;

        while (true) {
            const next_token = self.peek();
            if (next_token.type == TokenType.RBRACE) {
                break;
            } else if (next_token.type == TokenType.EOF) {
                return error.UnterminatedBlock;
            }
            try self.parse_declaration();
        }
        try self.consume(TokenType.RBRACE);
        // Pop all locals from this scope from the stack
        const current_scope_depth = self.scope_depth;
        self.scope_depth -= 1;

        var index = self.locals.items.len;
        while (index > 0) {
            index -= 1;
            // TODO: can probably be made more efficient
            const local = self.locals.items[index];
            if (local.scope_depth != current_scope_depth) break;
            _ = self.locals.pop();
            try self.emit_byte(@intFromEnum(OpCode.POP));
        }
    }

    pub fn parse_declaration(self: *Parser) anyerror!void {
        if (self.match(TokenType.LBRACE)) {
            try self.parse_block();
            return;
        }
        try self.parse_statement();
    }

    fn parse_statement(self: *Parser) !void {
        if (self.match(TokenType.PRINT)) {
            try self.parse_print_statement();
            return;
        }
        if (self.match(TokenType.VAR)) {
            try self.parse_variable_declaration();
            return;
        }
        try self.parse_expression_statement();
    }

    fn parse_print_statement(self: *Parser) !void {
        try self.parse_expression();
        try self.consume(.SEMICOLON);
        try self.emit_byte(@intFromEnum(OpCode.PRINT));
    }

    fn parse_variable_declaration(self: *Parser) !void {
        try self.consume(.IDENTIFIER);
        const identifier = self.previous_token();
        const identifier_name = self.source[identifier.start .. identifier.start + identifier.len];
        // TODO: declaration without value
        try self.consume(.EQUAL);
        try self.parse_expression();
        try self.consume(.SEMICOLON);
        if (self.scope_depth == 0) {
            try self.declare_global(identifier_name);
        } else {
            try self.declare_local(identifier_name);
        }
    }

    fn parse_expression_statement(self: *Parser) !void {
        try self.parse_expression();
        try self.consume(.SEMICOLON);
        try self.emit_byte(@intFromEnum(OpCode.POP));
    }

    fn parse_expression(self: *Parser) !void {
        try self.parse_precedence(Precedence.ASSIGNMENT);
    }

    fn parse_unary(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        const operator = self.previous_token().type;
        const parse_rule = self.parse_rules.get(operator) orelse return error.OperatorNotFound;
        try self.parse_precedence(@enumFromInt(@intFromEnum(parse_rule.precedence) + 1));
        try switch (operator) {
            TokenType.MINUS => self.emit_byte(@intFromEnum(OpCode.NEGATE)),
            else => unreachable,
        };
    }
    fn parse_binary(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        const operator = self.previous_token().type;
        const parse_rule = self.parse_rules.get(operator) orelse return error.OperatorNotFound;
        try self.parse_precedence(@enumFromInt(@intFromEnum(parse_rule.precedence) + 1));
        try switch (operator) {
            TokenType.PLUS => self.emit_byte(@intFromEnum(OpCode.ADD)),
            TokenType.MINUS => self.emit_byte(@intFromEnum(OpCode.SUBTRACT)),
            TokenType.STAR => self.emit_byte(@intFromEnum(OpCode.MULTIPLY)),
            TokenType.SLASH => self.emit_byte(@intFromEnum(OpCode.DIVIDE)),
            TokenType.LESS_THAN => self.emit_byte(@intFromEnum(OpCode.LESS_THAN)),
            TokenType.GREATER_THAN => self.emit_byte(@intFromEnum(OpCode.GREATER_THAN)),
            TokenType.EQUAL_EQUAL => self.emit_byte(@intFromEnum(OpCode.EQUALS)),
            else => unreachable,
        };
    }
    fn parse_number(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        const num_token = self.previous_token();
        const number = try std.fmt.parseFloat(
            std.meta.FieldType(LoxValue, .NUMBER),
            self.source[num_token.start .. num_token.start + num_token.len],
        );
        try self.emit_constant(LoxValue{ .NUMBER = number });
    }
    fn parse_string(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        const string_token = self.previous_token();
        // +1 and -1 to remove quotes.
        // TODO This doesn't handle any un-escaping
        const string_slice = try self.ctx.al.dupe(u8, self.source[string_token.start + 1 .. string_token.start + string_token.len - 1]);
        const string_object = try LoxObject.allocate_string(self.ctx, string_slice);
        try self.emit_constant(LoxValue{ .OBJECT = string_object });
    }
    fn parse_boolean(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        const num_token = self.previous_token();
        try self.emit_constant(LoxValue{
            .BOOLEAN = if (num_token.type == TokenType.TRUE) true else false,
        });
    }
    fn parse_identifier(self: *Parser, can_assign: bool) !void {
        const identifier = self.previous_token();
        const identifier_name = self.source[identifier.start .. identifier.start + identifier.len];
        if (can_assign and self.match(TokenType.EQUAL)) {
            try self.parse_expression();
            try self.set_variable(identifier_name);
        } else {
            try self.get_variable(identifier_name);
        }
    }
    fn parse_nil(self: *Parser, can_assign: bool) !void {
        _ = can_assign;
        try self.emit_constant(LoxValue{ .NIL = 0 });
    }
    pub fn end(self: *Parser) !void {
        try self.emit_byte(@intFromEnum(OpCode.EXIT));
    }

    fn emit_byte(self: *Parser, byte: u8) !void {
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
        const constant_index = try self.add_constant(value);
        try self.emit_bytes(@intFromEnum(OpCode.GET_CONST), constant_index);
    }

    fn add_global(self: *Parser, identifier: []u8) !u8 {
        const varnames = &self.chunk.varnames;
        try varnames.append(identifier);
        if (varnames.items.len > 256) {
            return error.TooManyGlobals;
        }
        return @intCast(varnames.items.len - 1);
    }

    fn declare_global(self: *Parser, identifier: []u8) !void {
        const global_index = try self.add_global(identifier);
        try self.emit_bytes(@intFromEnum(OpCode.DECLARE_GLOBAL), global_index);
    }

    fn set_global(self: *Parser, identifier: []u8) !void {
        const global_index = try self.add_global(identifier);
        try self.emit_bytes(@intFromEnum(OpCode.SET_GLOBAL), global_index);
    }

    fn get_global(self: *Parser, identifier: []u8) !void {
        // TODO: add deduplication of names in the names list.
        const global_index = try self.add_global(identifier);
        try self.emit_bytes(@intFromEnum(OpCode.GET_GLOBAL), global_index);
    }

    fn add_local(self: *Parser, identifier: []u8) !u8 {
        if (try self.find_local(identifier, true) != -1) {
            return error.RedeclaredLocal;
        }

        try self.locals.append(Local{
            .identifier = identifier,
            .scope_depth = self.scope_depth,
        });
        if (self.locals.items.len > 256) {
            return error.TooManyLocals;
        }
        return @intCast(self.locals.items.len - 1);
    }

    fn declare_local(self: *Parser, identifier: []u8) !void {
        const local_index = try self.add_local(identifier);
        try self.emit_bytes(@intFromEnum(OpCode.SET_LOCAL), local_index);
    }

    fn set_local(self: *Parser, identifier: []u8) !void {
        const local_index = try self.find_local(identifier, false);
        if (local_index == -1) {
            return error.UndeclaredVariable;
        }
        try self.emit_bytes(@intFromEnum(OpCode.SET_LOCAL), @intCast(local_index));
    }

    fn set_variable(self: *Parser, identifier: []u8) !void {
        if (self.scope_depth == 0) {
            try self.set_global(identifier);
        } else {
            try self.set_local(identifier);
        }
    }

    fn find_local(self: *Parser, identifier: []u8, same_scope: bool) !isize {
        var index = self.locals.items.len;
        while (index > 0) {
            index -= 1;
            const local = self.locals.items[index];
            if (same_scope and local.scope_depth != self.scope_depth) {
                continue;
            }
            if (std.mem.eql(u8, local.identifier, identifier)) {
                return @intCast(index);
            }
        }
        return -1;
    }

    fn get_variable(self: *Parser, identifier: []u8) !void {
        const local_index = try self.find_local(identifier, false);
        if (local_index == -1) {
            try self.get_global(identifier);
            return;
        }
        try self.emit_bytes(@intFromEnum(OpCode.GET_LOCAL), @intCast(local_index));
    }
};

const ParseFn = *const fn (*Parser, bool) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};
pub const ParseRules = std.AutoHashMap(TokenType, ParseRule);

const ParseRuleTuple = struct { TokenType, ParseRule };
// TODO: Trying to infer array length with `[_]` doesn't work right now, zig bug
pub const PARSE_RULES: [14]ParseRuleTuple = .{
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
        TokenType.IDENTIFIER,
        ParseRule{
            .prefix = Parser.parse_identifier,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
    .{
        TokenType.SEMICOLON,
        ParseRule{
            .prefix = null,
            .infix = null,
            .precedence = Precedence.NONE,
        },
    },
};
