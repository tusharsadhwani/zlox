const std = @import("std");

const TokenType = enum {
    UNKNOWN,
    PLUS,
    MINUS,
    MULTIPLY,
    DIVIDE,
    DOT,
    NUMBER,
};

const Token = struct {
    type: TokenType,
    start: usize,
    len: usize,
};

const Tokenizer = struct {
    start: usize,
    current: usize,
};

pub fn tokenize_number(source: []u8, start: usize) Token {
    var decimal_found = false;
    for (start + 1..source.len) |current| {
        const char = source[current];
        if (char == '.') {
            if (decimal_found) {
                return Token{ .type = TokenType.NUMBER, .start = start, .len = current - start };
            }
            decimal_found = true;
            continue;
        }
        if (char < '0' or char > '9') {
            return Token{ .type = TokenType.NUMBER, .start = start, .len = current - start };
        }
    }
    return Token{ .type = TokenType.NUMBER, .start = start, .len = source.len - start };
}

pub fn tokenize(al: std.mem.Allocator, source: []u8) !std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).init(al);

    var index: usize = 0;
    while (index < source.len) {
        const char = source[index];
        if (char == ' ' or char == '\n' or char == '\t') {
            index += 1;
            continue;
        }

        const token = switch (char) {
            '+' => Token{ .type = TokenType.PLUS, .start = index, .len = 1 },
            '-' => Token{ .type = TokenType.MINUS, .start = index, .len = 1 },
            '*' => Token{ .type = TokenType.MULTIPLY, .start = index, .len = 1 },
            '/' => Token{ .type = TokenType.DIVIDE, .start = index, .len = 1 },
            '.' => Token{ .type = TokenType.DOT, .start = index, .len = 1 },
            '0'...'9' => tokenize_number(source, index),
            else => Token{ .type = TokenType.UNKNOWN, .start = index, .len = 1 },
        };
        try tokens.append(token);
        index = index + token.len;
    }

    return tokens;
}
