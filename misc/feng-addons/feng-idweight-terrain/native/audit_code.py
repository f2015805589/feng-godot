"""Read-only, heuristic audits of the addon's native source; not a compiler or test suite.

    python audit_code.py dead                  declarations with few or no references (default)
    python audit_code.py undefined             header declarations without matching definitions
    python audit_code.py sections              .cpp banners versus header access specifiers
    python audit_code.py comments              comments naming absent identifiers
    python audit_code.py params                unread parameters in short definitions
    python audit_code.py indent                indentation runs, first statements and comments
    python audit_code.py shape                 file sizes and long definition spans
    python audit_code.py structure <function>  one matching function's top-level statements
    python audit_code.py dupes                 repeated normalized definition spans

Reports are review candidates. Name searches include binding strings and can conflate unrelated
symbols; external callers are not visible. Source scanners assume this addon's formatting and do
not implement C++ syntax. Shape/duplicate spans end at the next detected definition, so they may
include trailing declarations or comments. Parameter checks require a complete body within a
12-line window. All commands read files without modifying them.
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).parent / "src"
FILES = {}
for path in SRC.rglob("*"):
    if path.suffix in (".cpp", ".h", ".glsl"):
        FILES[path] = path.read_text(encoding="utf-8", errors="replace")

METHOD = re.compile(r"^(?:[A-Za-z_][\w:<>,*\s&]*?\s+)?(?:Terrain3D\w*|TerrainVT\w*)::([A-Za-z_]\w*)\s*\(", re.M)
FUNCTION_CEILING = 90


def hits(name: str) -> int:
    return sum(len(re.findall(r"\b" + re.escape(name) + r"\b", text)) for text in FILES.values())


def read(name: str) -> str:
    return FILES[SRC / name]


# Definitions begin at column 0; indented continuation lines and non-function scopes are excluded.
UNQUALIFIED = ("namespace", "using", "struct", "class", "enum", "template", "extern", "typedef",
               "return", "if", "for", "while", "switch", "static const", "#")
SIGNATURE = re.compile(r"^[A-Za-z_~][\w:<>,*&\s]*[\s*&:]([A-Za-z_]\w*)\s*\(")
RAW_STRING = re.compile(r'R"(\w*)\(', re.S)


def mask_literals(text: str) -> str:
    """Blank line comments and raw string literals, preserving offsets and newlines."""
    out = list(text)
    for match in re.finditer(r"//[^\n]*", text):
        for index in range(match.start(), match.end()):
            out[index] = " "
    position = 0
    while True:
        match = RAW_STRING.search(text, position)
        if not match:
            break
        closing = ')' + match.group(1) + '"'
        end = text.find(closing, match.end())
        end = len(text) if end < 0 else end + len(closing)
        for index in range(match.start(), end):
            if out[index] != "\n":
                out[index] = " "
        position = end
    return "".join(out)


def definitions(text: str):
    """Return (offset, name) for detected column-0 C++ definitions.

    Member and free functions are included; raw embedded shaders are masked. Missed definitions
    extend the preceding span, so reported lengths are approximate.
    """
    masked = mask_literals(text)
    starts = []
    offset = 0
    for line in masked.splitlines(keepends=True):
        if line[:1].isalpha() and not line.startswith(UNQUALIFIED) and not line.rstrip().endswith(";"):
            match = SIGNATURE.match(line)
            if match:
                starts.append((offset, match.group(1)))
        offset += len(line)
    return starts


def report(title: str, entries) -> None:
    print(f"== {title}")
    if not entries:
        print("   (none)")
    for name, detail in entries:
        print(f"   {name:42s} {detail}")


def dead() -> None:
    body = read("terrain_3d_vt_state.h").split("struct Terrain3DVTState {", 1)[1]
    fields = re.findall(r"^\t([A-Za-z_][\w:<>,\s\*&]*?)\s+([a-z_][a-z0-9_]*)\s*(?:=|;|\{|\[)", body, re.M)
    print(f"   ({len(fields)} Terrain3DVTState fields declared)")
    report("state fields nothing reads",
            [(n, f"declared as {t.strip()}") for t, n in fields if hits(n) <= 1])

    declared = set(re.findall(r"^\t(?:virtual\s+)?[A-Za-z_][\w:<>,*\s\*&]*?\s+(_?[a-z][a-z0-9_]*)\s*\(", read("terrain_3d.h"), re.M))
    keywords = {"if", "for", "while", "switch", "return", "sizeof", "defined", "MAX", "MIN", "CLAMP"}
    report("Terrain3D public methods referenced only where declared (check the bindings first)",
            [(n, f"{hits(n) - 1} reference(s) outside the declaration")
             for n in sorted(declared - keywords) if not n.startswith("_") and hits(n) <= 2])

    statics = []
    for path, text in FILES.items():
        if path.suffix != ".cpp":
            continue
        for name in re.findall(r"^static\s+[\w:<>,\s\*&]+?\s+([a-z_][a-z0-9_]*)\s*\(", text, re.M):
            if hits(name) <= 1:
                statics.append((name, f"static in {path.name}"))
    report("static functions nothing calls", statics)


def shape() -> None:
    print("   files by size")
    rows = []
    for path in sorted(SRC.glob("*.cpp")):
        text = path.read_text(encoding="utf-8", errors="replace")
        rows.append((text.count("\n") + 1, path.name, len(set(METHOD.findall(text)))))
    for lines, name, count in sorted(rows, reverse=True)[:14]:
        print(f"   {lines:6d} lines  {count:3d} methods  {name}")

    over = []
    for path in sorted(SRC.glob("*.cpp")):
        text = path.read_text(encoding="utf-8", errors="replace")
        marks = definitions(text)
        for index, (start, name) in enumerate(marks):
            end = marks[index + 1][0] if index + 1 < len(marks) else len(text)
            span = text[start:end].count("\n")
            if span > FUNCTION_CEILING:
                over.append((span, name, path.name))
    report(f"definitions over {FUNCTION_CEILING} lines",
            [(f"{span:5d} lines  {func}", name) for span, func, name in sorted(over, reverse=True)])


def structure(needle: str) -> None:
    """Print a matching function's top-level statements using a simple brace scan."""
    for path, text in FILES.items():
        if needle not in text:
            continue
        start = text.index(needle)
        depth = 0
        began = False
        body_start = 0
        i = start
        while i < len(text):
            if text.startswith("//", i):
                i = text.index("\n", i)
                continue
            if text[i] == '"':
                i = text.index('"', i + 1) + 1
                continue
            if text[i] == "{":
                depth += 1
                if depth == 1:
                    began = True
                    body_start = i
            elif text[i] == "}":
                depth -= 1
                if began and depth == 0:
                    break
            i += 1
        body = text[body_start:i]
        print(f"=== {path.name}: {needle} ({body.count(chr(10))} lines)")
        depth = 0
        for offset, line in enumerate(body.splitlines()):
            if depth == 1 and line.strip() and not line.strip().startswith("/*"):
                print(f"  {offset:4d} {line[:112]}")
            depth += line.count("{") - line.count("}")
        return
    print(f"not found: {needle}")


def dupes(minimum: int = 6) -> None:
    """Compare definition spans after masking line comments/raw strings and trimming lines.

    Braces on their own lines are ignored; identifiers are not normalized.
    """
    groups = {}
    for path, text in FILES.items():
        if path.suffix != ".cpp":
            continue
        masked = mask_literals(text)
        marks = definitions(text)
        for index, (start, name) in enumerate(marks):
            end = marks[index + 1][0] if index + 1 < len(marks) else len(text)
            lines = [line.strip() for line in masked[start:end].splitlines()[1:]
                     if line.strip() and line.strip() not in ("{", "}")]
            if len(lines) >= minimum:
                groups.setdefault(tuple(lines), []).append((name, path.name))

    found = [(body, where) for body, where in groups.items() if len(where) > 1]
    print(f"   ({len(groups)} definitions compared, {len(found)} written more than once)")
    for body, where in sorted(found, key=lambda item: -len(item[1])):
        print(f"== {len(body)} identical lines, {len(where)} copies")
        for name, source in where:
            print(f"   {name:44s} {source}")
        print(f"   first line: {body[0][:88]}")


# Match indented declarations across lines, excluding inline, pure-virtual and defaulted bodies.
DECLARATION = re.compile(
    r"^[ \t]+(?:virtual\s+|static\s+|inline\s+|explicit\s+|constexpr\s+)*"
    r"[A-Za-z_~][\w:<>,*&\s]*?[\s*&]([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:const\s*)?;", re.M)
CLASS_OPENER = re.compile(r"\s*(?:class|struct)\s+([A-Za-z_]\w*)")
# Macros that look exactly like a declaration and are not one.
NOT_A_METHOD = {"GDCLASS", "CLASS_NAME", "CLASS_NAME_STATIC", "ADD_PROPERTY", "ADD_SIGNAL",
                "ADD_GROUP"}


def enclosing_classes(text: str):
    """Return the innermost class scope and brace depth for each line.

    Declaration depth distinguishes class members from locals in inline bodies.
    """
    scopes = []
    depths = []
    stack = []
    depth = 0
    for line in mask_literals(text).splitlines():
        opener = CLASS_OPENER.match(line)
        if opener:
            stack.append((opener.group(1), depth + 1))
        depths.append(depth)
        depth += line.count("{") - line.count("}")
        while stack and depth < stack[-1][1]:
            stack.pop()
        scopes.append(stack[-1] if stack else None)
    return scopes, depths


def undefined() -> None:
    """Find header declarations without a matching class-qualified or file-scope definition."""
    qualified = set()
    plain = set()
    for path, text in FILES.items():
        qualified.update(re.findall(r"\b(\w+)::([A-Za-z_]\w*)\s*\(", text))
        for line in text.splitlines():
            if not line[:1].isalpha() or line.rstrip().endswith(";"):
                continue
            match = re.match(r"[A-Za-z_][\w:<>,*&\s]*?[\s*&]([A-Za-z_]\w*)\s*\(", line)
            if match:
                plain.add(match.group(1))

    class_scope, file_scope = [], []
    for path, text in FILES.items():
        if path.suffix != ".h":
            continue
        scopes, depths = enclosing_classes(text)
        for match in DECLARATION.finditer(text):
            name = match.group(1)
            if name in NOT_A_METHOD:
                continue
            index = text.count("\n", 0, match.start())
            scope = scopes[index]
            where = "%s, %s" % (path.name, scope[0] if scope else "file scope")
            if scope is None:
                # `depths` excludes the inline bodies a free function's definition contains.
                if depths[index] == 0 and name not in plain:
                    file_scope.append((name, where))
            elif depths[index] == scope[1] and (scope[0], name) not in qualified:
                class_scope.append(("%s::%s" % (scope[0], name), where))

    report("declared in a class and defined nowhere", sorted(class_scope))
    report("declared at file scope and defined nowhere", sorted(file_scope))


# Any title-case banner ends the previous section, including non-access sub-banners.
ACCESS = re.compile(r"^(public|private|protected)\s*:")
BANNER = re.compile(r"^//\s*([A-Z][A-Za-z ]*?)\s*$")
DEFINITION = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?\b(\w+)::([A-Za-z_]\w*)\s*\(")
# Include inline accessors and signatures whose closing semicolon falls on another line.
HEADER_NAME = re.compile(
    r"^[ \t]+(?:virtual\s+|static\s+|inline\s+|explicit\s+|constexpr\s+)*"
    r"[A-Za-z_~][\w:<>,*&\s]*?[\s*&]([A-Za-z_]\w*)\s*\(")


def header_access(text: str):
    """name -> the access specifier that encloses its declaration."""
    names = {}
    access = None
    for line in text.splitlines():
        match = ACCESS.match(line.strip())
        if match:
            access = match.group(1)
            continue
        if access is None or line.strip().startswith("//"):
            continue
        match = HEADER_NAME.match(line)
        if match and match.group(1) not in NOT_A_METHOD:
            names.setdefault(match.group(1), access)
    return names


def definition_sections(text: str):
    """(banner, name) for each column-0 definition, in file order."""
    found = []
    banner = "(no banner)"
    for line in text.splitlines():
        match = BANNER.match(line)
        if match:
            banner = match.group(1)
            continue
        match = DEFINITION.match(line)
        if match and match.group(1)[0].isupper():
            found.append((banner, match.group(2)))
    return found


def sections() -> None:
    """Compare access banners with declarations in the paired or included class header.

    Files without access banners are skipped; unmatched public definitions are listed separately.
    """
    disagreement = []
    undeclared = []
    checked = 0
    for path, text in FILES.items():
        if path.suffix != ".cpp":
            continue
        header = FILES.get(path.with_suffix(".h"))
        if header is None:
            # Split implementations use the included header declaring their class, not the first include.
            classes = set(re.findall(r"\b(\w+)::\w+\s*\(", text))
            for candidate in re.findall(r'^#include "([^"]+\.h)"', text, re.M):
                candidate_text = FILES.get(SRC / candidate)
                if candidate_text and any(re.search(r"\bclass %s\b" % name, candidate_text) for name in classes):
                    header = candidate_text
                    break
        if header is None:
            continue
        access = header_access(header)
        found = definition_sections(text)
        if not any(banner in ("Private Functions", "Public Functions") for banner, _ in found):
            continue
        checked += 1
        for banner, name in found:
            if banner == "Private Functions" and access.get(name) in ("public", "protected"):
                disagreement.append((name, "%s in the header, under Private Functions" % access[name]))
            elif banner == "Public Functions" and access.get(name) in ("private", "protected"):
                disagreement.append((name, "%s in the header, under Public Functions" % access[name]))
            elif banner == "Public Functions" and name not in access:
                undeclared.append((name, path.name))
    print("   (%d files carry the two banners)" % checked)
    report("banner and access disagree", sorted(disagreement))
    report("defined under Public Functions and declared in no header", sorted(undeclared))


# Inspect backticked names, empty calls and private-prefixed identifiers, not ordinary prose.
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.S)
COMMENT_LINE = re.compile(r"//[^\n]*")
BACKTICKED = re.compile(r"`([A-Za-z_]\w*(?:::\w+)*)(?:\(\))?`")
CALLED = re.compile(r"\b([a-z_]\w{3,})\s*\(\)")
PRIVATE = re.compile(r"\b(_[a-z]\w{3,})\b")
# Known engine and standard-library names allowed in comments.
FOREIGN = {"_process", "_physics_process", "_process_message", "_execute_frame", "_notification",
           "is_in_tree", "try_lock", "strip", "decode_u16", "encode_u16", "get_format_pixel_size",
           "get_sample_view"}
# Read comments in src/, but resolve names against the whole addon, including scripts and tests.
CORPUS = (".cpp", ".h", ".glsl", ".gdshader", ".gd", ".py", ".tres")
SKIP_DIRS = ("bin", "godot-cpp", ".git")
ADDON = SRC.parent.parent


def without_comments(text: str) -> str:
    text = COMMENT_BLOCK.sub(lambda match: " " * len(match.group(0)), text)
    return COMMENT_LINE.sub(lambda match: " " * len(match.group(0)), text)


def comment_spans(text: str):
    """(comment text, the line it starts on) for every // and /* */ comment."""
    for match in COMMENT_BLOCK.finditer(text):
        yield match.group(0), text.count("\n", 0, match.start()) + 1
    for match in COMMENT_LINE.finditer(text):
        yield match.group(0), text.count("\n", 0, match.start()) + 1


def comments() -> None:
    """Find comment identifiers absent from addon code, except known external names.

    Keep raw strings visible because embedded shader identifiers belong to the corpus.
    """
    code_words = set()
    for path in ADDON.rglob("*"):
        if path.suffix not in CORPUS or any(part in SKIP_DIRS for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        code_words.update(re.findall(r"[A-Za-z_]\w*", without_comments(text)))

    hits = {}
    for path, text in FILES.items():
        for body, first_line in comment_spans(text):
            for regex in (BACKTICKED, CALLED, PRIVATE):
                for match in regex.finditer(body):
                    name = match.group(1).split("::")[-1]
                    if name in code_words or name in FOREIGN:
                        continue
                    # Ignore wildcard suffixes such as `*_sum_ms`.
                    if match.start() and body[match.start() - 1] == "*":
                        continue
                    line = first_line + body[:match.start()].count("\n")
                    hits.setdefault(name, set()).add("%s:%d" % (path.name, line))

    print("   (%d names in the corpus, %d comment references that match none)"
            % (len(code_words), len(hits)))
    report("comments naming an identifier the addon does not define",
            [(name, ", ".join(sorted(hits[name])[:4])) for name in sorted(hits)])


# Distinguish column-0 definitions from control flow and declarations in flush namespaces.
DEFINITION_HEAD = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?(?:\w+::)?([A-Za-z_]\w*)\s*\(")
NOT_A_FUNCTION = {"if", "for", "while", "switch", "return", "else", "do", "catch", "case", "break",
                  "continue", "class", "struct", "enum", "union", "typedef", "using", "template",
                  "namespace", "extern"}
PARAMETER_NAME = re.compile(r"([A-Za-z_]\w*)\s*(?:\[\s*\])?\s*$")


def code_only(text: str) -> str:
    """Blank comments and literals in one pass, preserving offsets and newlines.

    Left-to-right scanning keeps comment markers inside strings from becoming comments.
    """
    out = []
    index = 0
    while index < len(text):
        two = text[index:index + 2]
        if two == "//":
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
        elif two == "/*":
            end = text.find("*/", index + 2)
            end = len(text) if end < 0 else end + 2
        elif text.startswith("R\"", index) and "(" in text[index:index + 18]:
            # Raw strings can contain multiline shaders; scan to the matching delimiter.
            paren = text.index("(", index)
            closing = ")" + text[index + 2:paren] + "\""
            found = text.find(closing, paren)
            end = len(text) if found < 0 else found + len(closing)
        elif text[index] in "\"'":
            quote = text[index]
            end = index + 1
            while end < len(text) and text[end] != quote and text[end] != "\n":
                end += 2 if text[end] == "\\" else 1
            end = min(len(text), end + 1)
        else:
            out.append(text[index])
            index += 1
            continue
        out.append("".join("\n" if char == "\n" else " " for char in text[index:end]))
        index = end
    return "".join(out)


def matching(text: str, start: int, open_char: str, close_char: str) -> int:
    depth = 0
    for index in range(start, len(text)):
        if text[index] == open_char:
            depth += 1
        elif text[index] == close_char:
            depth -= 1
            if depth == 0:
                return index
    return -1


def split_parameters(text: str):
    """Top-level comma split, so a template argument's comma does not cut a parameter in half."""
    chunks = []
    depth = 0
    current = []
    for char in text:
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        if char == "," and depth == 0:
            chunks.append("".join(current))
            current = []
            continue
        current.append(char)
    chunks.append("".join(current))
    return chunks


def params() -> None:
    """Find unread parameters in definitions whose complete body fits a 12-line window."""
    reported = 0
    for path, text in sorted(FILES.items()):
        if path.suffix != ".cpp":
            continue
        code = code_only(text)
        lines = code.split("\n")
        for index, line in enumerate(lines):
            if line[:1] not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_":
                continue
            head = DEFINITION_HEAD.match(line)
            if not head or head.group(1) in NOT_A_FUNCTION:
                continue
            if line.split("::")[0].split() and line.split("::")[0].split()[0] in NOT_A_FUNCTION:
                continue
            joined = "\n".join(lines[index:index + 12])
            open_at = joined.find("(")
            close_at = matching(joined, open_at, "(", ")")
            body_at = joined.find("{", close_at)
            # A semicolon before the brace ends a declaration, not this function's signature.
            if ";" in joined[close_at:body_at]:
                continue
            body_end = matching(joined, body_at, "{", "}") if body_at >= 0 else -1
            if close_at < 0 or body_at < 0 or body_end < 0:
                continue
            body = joined[body_at:body_end]
            for chunk in split_parameters(joined[open_at + 1:close_at]):
                chunk = chunk.split("=")[0].strip()
                if not chunk or chunk == "void":
                    continue
                match = PARAMETER_NAME.search(chunk)
                if not match:
                    continue
                name = match.group(1)
                if not re.search(r"\b" + re.escape(name) + r"\b", body):
                    reported += 1
                    print("   %-32s line %-5d %-30s %s" % (path.name, index + 1, head.group(1), name))
    print("%d parameter(s) never read" % reported)


# A `namespace` or `extern "C"` body is written flush with the keyword, so its brace adds no level.
FLUSH_BRACE = re.compile(r"\s*(namespace|extern)\b")
# Open parentheses and trailing operators permit continuation indentation.
CONTINUATION = ("+", "-", "|", "&", ",", "=", "?", ":", "\\")
BODY_HEAD = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?(?:\w+::)?([A-Za-z_]\w*)\s*\(")


def indent() -> None:
    """Report long indentation mismatches, misplaced first statements and column-0 comments.

    Continuation lines may use one extra level. First statements are checked separately;
    inline and empty bodies have no separate statement to measure. Comments are checked
    against their nearest nonblank neighbors because code_only() masks them.
    """
    runs = []
    deep = []
    misplaced = []
    # Requiring indented neighbors on both sides excludes file/namespace-level shader comments.
    for path, text in sorted(FILES.items()):
        if path.suffix not in (".cpp", ".h"):
            continue
        lines = text.split("\n")
        meaningful = [index for index, line in enumerate(lines) if line.strip()]
        for position, index in enumerate(meaningful):
            if position == 0 or position + 1 == len(meaningful) or not lines[index].startswith("//"):
                continue
            above = lines[meaningful[position - 1]]
            below = lines[meaningful[position + 1]]
            if above[:1] in ("\t", " ") and below[:1] in ("\t", " "):
                misplaced.append((path.name, index + 1))
    for path, text in sorted(FILES.items()):
        if path.suffix not in (".cpp", ".h"):
            continue
        code_lines = code_only(text).split("\n")
        raw_lines = text.split("\n")
        stack = []
        parens = 0
        carry = False
        current = []
        for index, code in enumerate(code_lines):
            raw = raw_lines[index]
            stripped = code.strip()
            if not stripped or stripped.startswith("#"):
                if current:
                    current.append((index + 1, None))
                continue
            expected = sum(1 for level in stack if level)
            if stripped.startswith("}") and stack and stack[-1]:
                expected -= 1
            tabs = len(raw) - len(raw.lstrip("\t"))
            if parens == 0 and not carry and (tabs > expected + 1 or tabs < expected):
                current.append((index + 1, tabs - expected))
            else:
                real = [entry for entry in current if entry[1] is not None]
                if len(real) >= 3:
                    runs.append((path.name, real[0][0], real[-1][0], len(real),
                                 sorted({entry[1] for entry in real})))
                current = []
            indent_less = FLUSH_BRACE.match(stripped) is not None
            for char in code:
                if char == "{":
                    stack.append(not indent_less)
                elif char == "}":
                    if stack:
                        stack.pop()
            parens = max(0, parens + code.count("(") - code.count(")"))
            carry = parens > 0 or code.rstrip().endswith(CONTINUATION)
            # Check the first statement of column-0 definitions separately from continuation runs.
            head = BODY_HEAD.match(code)
            if head and head.group(1) not in NOT_A_FUNCTION:
                if code.split("::")[0].split() and code.split("::")[0].split()[0] in NOT_A_FUNCTION:
                    continue
                window = "\n".join(code_lines[index:index + 12])
                open_at = window.find("(")
                close_at = matching(window, open_at, "(", ")")
                body_at = window.find("{", close_at) if close_at >= 0 else -1
                if body_at < 0 or ";" in window[close_at:body_at]:
                    continue
                # Inline bodies have no separate first-statement line to measure.
                tail_at = window.find("\n", body_at)
                tail = window[body_at + 1:tail_at if tail_at >= 0 else len(window)]
                if tail.strip():
                    continue
                body_line = index + window[:body_at].count("\n") + 1
                body_expected = expected + 1
                while body_line < len(code_lines):
                    body_stripped = code_lines[body_line].strip()
                    if body_stripped and not body_stripped.startswith(("//", "#")):
                        if body_stripped.startswith("}"):
                            break  # An empty body: its closing brace is not a statement.
                        body_tabs = len(raw_lines[body_line]) - len(raw_lines[body_line].lstrip("\t"))
                        if body_tabs != body_expected:
                            deep.append((path.name, body_line + 1, body_tabs, body_expected,
                                         raw_lines[body_line].strip()[:58]))
                        break
                    body_line += 1
        real = [entry for entry in current if entry[1] is not None]
        if len(real) >= 3:
            runs.append((path.name, real[0][0], real[-1][0], len(real),
                         sorted({entry[1] for entry in real})))
    print("== mis-indented runs (three lines or more)")
    if not runs:
        print("   (none)")
    for name, first, last, count, offsets in runs:
        print("   %-30s %d-%d  %d line(s), offsets %s" % (name, first, last, count, offsets))
    print("== bodies whose first statement is not at the expected depth")
    if not deep:
        print("   (none)")
    for name, line, tabs, expected, text_of_line in deep:
        print("   %-30s line %-5d tabs=%d expected=%d  %s" % (name, line, tabs, expected, text_of_line))
    print("== comments written as if they were outside the body they are in")
    if not misplaced:
        print("   (none)")
    for name, line in misplaced:
        print("   %-30s line %-5d" % (name, line))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "dead"
    if what == "dead":
        dead()
    elif what == "undefined":
        undefined()
    elif what == "sections":
        sections()
    elif what == "comments":
        comments()
    elif what == "params":
        params()
    elif what == "indent":
        indent()
    elif what == "shape":
        shape()
    elif what == "dupes":
        dupes()
    elif what == "structure" and len(sys.argv) > 2:
        for argument in sys.argv[2:]:
            structure(argument)
    else:
        print(__doc__)
        sys.exit(2)
