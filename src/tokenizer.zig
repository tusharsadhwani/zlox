const std = @import("std");

pub const TokenType = enum {
    UNKNOWN,
    PLUS,
    MINUS,
    STAR,
    SLASH,
    DOT,
    EQUAL,
    EQUAL_EQUAL,
    GREATER_THAN,
    LESS_THAN,
    NUMBER,
    IDENTIFIER,
    TRUE,
    FALSE,
    NIL,
    EOF,
};

pub const Token = struct {
    type: TokenType,
    start: usize,
    len: usize,
};

fn tokenize_number(source: []u8, start: usize) Token {
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

fn tokenize_identifier(source: []u8, start: usize) Token {
    if (source.len >= start + 4 and std.mem.eql(u8, source[start .. start + 4], "true")) {
        return Token{ .type = .TRUE, .start = start, .len = 4 };
    }
    if (source.len >= start + 5 and std.mem.eql(u8, source[start .. start + 5], "false")) {
        return Token{ .type = .FALSE, .start = start, .len = 5 };
    }
    if (source.len >= start + 3 and std.mem.eql(u8, source[start .. start + 3], "nil")) {
        return Token{ .type = .NIL, .start = start, .len = 3 };
    }

    for (start + 1..source.len) |current| {
        const char = source[current];
        if (char < 'A' or char > 'z' or (char > 'Z' and char < 'a')) {
            return Token{ .type = TokenType.IDENTIFIER, .start = start, .len = current - start };
        }
    }
    return Token{ .type = TokenType.IDENTIFIER, .start = start, .len = source.len - start };
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
            // TOOD: Add += -= etc.
            '+' => Token{ .type = TokenType.PLUS, .start = index, .len = 1 },
            '-' => Token{ .type = TokenType.MINUS, .start = index, .len = 1 },
            '*' => Token{ .type = TokenType.STAR, .start = index, .len = 1 },
            '/' => Token{ .type = TokenType.SLASH, .start = index, .len = 1 },
            '=' => if (index + 1 < source.len and source[index + 1] == '=')
                Token{ .type = TokenType.EQUAL_EQUAL, .start = index, .len = 2 }
            else
                Token{ .type = TokenType.EQUAL, .start = index, .len = 1 },
            '>' => Token{ .type = TokenType.GREATER_THAN, .start = index, .len = 1 },
            '<' => Token{ .type = TokenType.LESS_THAN, .start = index, .len = 1 },
            '.' => Token{ .type = TokenType.DOT, .start = index, .len = 1 },
            '0'...'9' => tokenize_number(source, index),
            'A'...'Z', 'a'...'z' => tokenize_identifier(source, index),
            else => Token{ .type = TokenType.UNKNOWN, .start = index, .len = 1 },
        };
        try tokens.append(token);
        index = index + token.len;
    }

    try tokens.append(Token{ .type = TokenType.EOF, .start = source.len, .len = 0 });
    return tokens;
}
