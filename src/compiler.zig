
const tokenizer = @import("tokenizer.zig");
const TokenType = tokenizer.TokenType;
const parse = @import("parse.zig");
const Chunk = parse.Chunk;
const Parser = parse.Parser;
const GlobalContext = @import("context.zig").GlobalContext;
const types = @import("types.zig");

pub const OpCode = enum(u8) {
    EXIT,
    POP,
    PRINT,
    GET_CONST,
    DECLARE_GLOBAL,
    SET_GLOBAL,
    GET_GLOBAL,
    SET_LOCAL,
    GET_LOCAL,
    // TODO: use a BINARY_OP opcode
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    NEGATE,
    LESS_THAN,
    GREATER_THAN,
    EQUALS,
};

pub fn compile(ctx: *GlobalContext, tokens: []tokenizer.Token, source: []u8) !*Chunk {
    const chunk = try Chunk.create(ctx.al);
    errdefer chunk.free();

    var parse_rules = parse.ParseRules.init(ctx.al);
    defer parse_rules.deinit();
    for (parse.PARSE_RULES) |parse_rule_tuple| {
        const token_type = parse_rule_tuple[0];
        const rule = parse_rule_tuple[1];
        try parse_rules.put(token_type, rule);
    }

    var parser = Parser.init(ctx, source, tokens, chunk, parse_rules);
    defer parser.deinit();

    while (parser.peek().type != TokenType.EOF) {
        try parser.parse_declaration();
    }
    try parser.consume(TokenType.EOF);
    if (parser.current != parser.tokens.len) {
        return error.UnexpectedEOF;
    }
    try parser.end();
    return chunk;
}
