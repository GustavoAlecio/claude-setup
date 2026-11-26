import re


def glob_body(pattern):
    """Regex source of a glob: `[...]` is a class (`!` negates), `{a,b}` is alternatives; unclosed or nested stays literal."""
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
            continue
        if c == "[":
            end = pattern.find("]", i + 1)
            negated = pattern.startswith("!", i + 1)
            chars = pattern[i + 2 if negated else i + 1:max(end, 0)]
            # A negated class would otherwise match `/` and let one segment cross directories.
            cls = "[" + ("^/" if negated else "") + re.sub(r"([\\\[\]^&|~])", r"\\\1", chars) + "]"
            if chars and compiles(cls):
                out += cls
                i = end + 1
                continue
        if c == "{":
            end = brace_end(pattern, i)
            if end:
                inner = pattern[i + 1:end]
                nested = "{" in inner
                out += re.escape(pattern[i:end + 1]) if nested else "(?:" + "|".join(map(glob_body, inner.split(","))) + ")"
                i = end + 1
                continue
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return out


def brace_end(pattern, start):
    depth = 0
    for j in range(start, len(pattern)):
        depth += {"{": 1, "}": -1}.get(pattern[j], 0)
        if depth == 0:
            return j
    return 0


def compiles(source):
    try:
        re.compile(source)
    except re.error:
        return False
    return True


def glob_re(pattern):
    return re.compile("^" + glob_body(pattern) + "$")
