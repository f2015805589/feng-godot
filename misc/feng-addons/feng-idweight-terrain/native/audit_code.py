"""Read-through helpers for the addon's own source.

Not part of the test suite and not run by anything: this is the tool the architecture pass uses to
answer its questions mechanically instead of by eye, so the answers do not depend on reading thirty
thousand lines carefully.

    python audit_code.py dead                    declarations nothing in src/ references
    python audit_code.py undefined               header declarations nothing implements
    python audit_code.py sections                .cpp banners vs the header's access specifiers
    python audit_code.py comments                comments naming identifiers that no longer exist
    python audit_code.py params                  parameters a definition never reads
    python audit_code.py indent                  mis-indented runs, and bodies a level too deep
    python audit_code.py shape                   what each file holds, and what outgrew it
    python audit_code.py structure <function>    one function's top-level statements
    python audit_code.py dupes                   definitions written more than once

`dead` is what found the experimental distance-mip controls and the unused `get_warnings()` accessor:
a symbol that appears only where it is declared is dead, while a symbol used from an inline accessor
in the same header, or named by an `ADD_PROPERTY` binding string, is not - so the binding names are
part of the search. It reports candidates, not verdicts: a property getter named only from its
binding is live, and the report says which case each candidate is.

`undefined` is the check that catches `Terrain3DVTPagePool::get_atlas_image()`, declared beside the
live `Terrain3DVirtualTexture::get_atlas_image()` and written nowhere. Matching by name cannot see
it - the name is defined, just not for that class - so this one attributes each declaration to the
class that encloses it and asks for that qualified definition. Nothing else reports it: the compiler
is silent because nothing calls it, and `dead` counts the name as used because the other class has a
method by the same name.

`sections` is the one check about the *file* rather than the code: a definition under a "Private
Functions" banner whose declaration in the paired header says `public:` is a file that reads as if
that function were callable from outside, and the compiler never objects. It found thirteen of them
in four files - eight private streamer helpers under a "Public Functions" banner, three public
`Terrain3DAssets` array setters under "Private Functions", and two single cases - which are moves,
not rewrites, once the header says where they belong.

`comments` is the prose half: a comment that names an identifier the code no longer contains, which
is the same kind of lie as a stale banner and cannot be found by reading the code. It found
`_lod_rids` (a comment beside `_clipmap_rids`), `Terrain3D::_process_physics()`, `_operate()` and
`_get_undo_data()`, all four of which name something that no longer exists under that name. Most of
what it reports is *not* a defect - engine internals (`Node::_process()`,
`RenderingDeviceGraph::_execute_frame()`, `std::mutex::try_lock()`), GDScript reachable through
`call()`, prose that happens to be underscored - so it reports candidates and this file names the
forgiven ones.

`params` is the one the compiler could make and does not. An unused parameter needs
`-Wunused-parameter`, and a parameter *dropped* on the way to the call it forwards to is not reported
at all - the function works, it just ignores what it was handed. It found
`Terrain3DData::add_region_blankp()`, bound to Godot with `update` exposed and forwarded without it,
and `Terrain3D::_svt_page_path()`'s `p_mip`, hard-coded to 0 in the body. Two of its own traps are
worth knowing: a declaration whose `;` precedes the brace made the *next* function its body, and raw
strings span lines, so the embedded shaders' `layout(set = 0, binding = 0)` lines were read as this
addon's definitions until raw strings were handled.

`shape` is what found `_update_visible_svt()`, which had grown to 484 lines with six stages in it and
no way to find one of them; extracting the root pyramid into `_svt_plan_roots()` took it to 283. Two
hundred lines is a reasonable ceiling for a function that runs stages in order, and this is the only
cheap way to notice which ones crossed it. It also found
`Terrain3DSurfaceBaker::render_pending()` at 272 lines.

`structure` is the other half of that: once a function is known to be too big, this prints what it
does at its top level, so the stages to extract can be named before anything is moved. It tracks brace
depth with comments and string literals skipped, which a plain brace count cannot do here - this
codebase quotes shader code and braces inside comments, and a naive counter reports a function ending
in the middle of its own explanation.
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


# Lines that start a definition: column 0, not a comment, not a preprocessor line, not a closing
# brace, and not one of the things that open a scope without being a function. Continuation lines of
# a multi-line signature are indented, so the signature's *first* line is what this finds.
UNQUALIFIED = ("namespace", "using", "struct", "class", "enum", "template", "extern", "typedef",
               "return", "if", "for", "while", "switch", "static const", "#")
SIGNATURE = re.compile(r"^[A-Za-z_~][\w:<>,*&\s]*[\s*&:]([A-Za-z_]\w*)\s*\(")
RAW_STRING = re.compile(r'R"(\w*)\(', re.S)


def mask_literals(text: str) -> str:
    """Blank out comments and raw string literals, keeping every offset and newline.

    This codebase embeds its shaders as `R"( ... )"`. The GLSL inside sits at column 0 and looks
    exactly like a definition - `vec4 encode_vec4(...) {`, `void main() {` - so a line-based scan that
    does not mask them reports shader functions, with the spans between them, as the addon's largest
    definitions. It reported `encode_vec4` at 1699 lines, which is how this was noticed.
    """
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
    """Every C++ definition in a translation unit, as (offset, name), member or namespace scope.

    A span is measured from one of these to the next, so anything this misses is silently *added* to
    its predecessor rather than going unreported. That happened twice: a namespace-scope `static`
    function following a nine-line setter made the setter read as 229 lines (member-only matching
    cannot see free functions), and the fix for that read the embedded shaders as definitions until
    they were masked.
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
    """Print one function's top-level statements, so a 300-line body can be planned before editing it."""
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
    """Definitions whose bodies are identical once comments and indentation are dropped.

    The complement of `dead`: that finds code nothing reads, this finds code written twice. Bodies are
    compared as line sequences with whitespace stripped, so a copy that has been reformatted still
    matches, while a copy whose identifiers were renamed does not - which under-reports rather than
    producing pairs a reader has to reject one by one.
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


# A declaration inside a class body: an indented type and name, ending in `);`, possibly wrapped
# over several lines. `[^;{}]` lets the argument list span lines but not run past a body, so an
# inline accessor's `{` stops the match, and `= 0` / `= default` never match at all because the
# pattern wants the `;` right after the parameter list.
DECLARATION = re.compile(
    r"^[ \t]+(?:virtual\s+|static\s+|inline\s+|explicit\s+|constexpr\s+)*"
    r"[A-Za-z_~][\w:<>,*&\s]*?[\s*&]([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:const\s*)?;", re.M)
CLASS_OPENER = re.compile(r"\s*(?:class|struct)\s+([A-Za-z_]\w*)")
# Macros that look exactly like a declaration and are not one.
NOT_A_METHOD = {"GDCLASS", "CLASS_NAME", "CLASS_NAME_STATIC", "ADD_PROPERTY", "ADD_SIGNAL",
                "ADD_GROUP"}


def enclosing_classes(text: str):
    """(scope per line, brace depth per line): the innermost class open, and how deep we are.

    Depth is tracked per line rather than per declaration, because a nested struct, an inline
    accessor's body, or a free function after the closing brace all have to be placed correctly:
    a declaration attributed to the wrong class reads as unimplemented, and one attributed to no
    class at all would be checked against the wrong definition. The depth is what tells a
    declaration in the class body from a local variable inside an inline body - `Vector2i loc(a, b);`
    is not a method, and reporting it was the first version of this check's whole output.
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
    """Declarations in a header that no translation unit implements.

    The complement of `dead`: that finds a name nothing *calls*, this finds a name nothing
    *defines* - a promise in a header with no body anywhere. A name-based search cannot do it,
    which is why this exists: `Terrain3DVTPagePool::get_atlas_image()` was invisible to both the
    compiler (nothing calls it) and `dead` (the name is used, by the other class that declares a
    method with it), so only asking for the *qualified* definition finds it.
    """
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


# A definition the .cpp owns: `Type Class::name(` on a column-0 line. The banner pattern takes any
# `// Words` line, so a file's own sub-banners ("Settings", "Bindings") end the section they follow
# instead of being misread as one of the two access banners.
ACCESS = re.compile(r"^(public|private|protected)\s*:")
BANNER = re.compile(r"^//\s*([A-Z][A-Za-z ]*?)\s*$")
DEFINITION = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?\b(\w+)::([A-Za-z_]\w*)\s*\(")
# Looser than DECLARATION on purpose: an inline accessor in a header (`bool is_ready() const { ... }`)
# is a declaration this has to see, and so is a signature whose default arguments push the `;` past
# the line the name sits on. The first version reused DECLARATION and reported eight methods that
# were declared inline in the very header it was reading.
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
    """.cpp section banners that disagree with the header's access specifiers.

    The defect is a file that reads as if a private helper were callable from outside, or as if a
    public setter were internal. Only files carrying both banners are checked - a file with no banner
    makes no claim - and a definition under "Public Functions" that no header declares is listed
    separately, because one free function there is legal but a pattern of them is not.
    """
    disagreement = []
    undeclared = []
    checked = 0
    for path, text in FILES.items():
        if path.suffix != ".cpp":
            continue
        header = FILES.get(path.with_suffix(".h"))
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


# Comment shapes that name code: backticked (`name`, `Class::name`), an empty parameter list
# (`name()`), and this codebase's private prefix (`_name`). Ordinary prose is not collected unless it
# wears one of those shapes, which is what keeps the report short: underscores used for emphasis are
# the one false-positive class left, and they read as such.
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.S)
COMMENT_LINE = re.compile(r"//[^\n]*")
BACKTICKED = re.compile(r"`([A-Za-z_]\w*(?:::\w+)*)(?:\(\))?`")
CALLED = re.compile(r"\b([a-z_]\w{3,})\s*\(\)")
PRIVATE = re.compile(r"\b(_[a-z]\w{3,})\b")
# Names this addon does not define and a comment is right to use anyway: engine and standard-library
# members. Kept here rather than in a data file so the check's forgiveness is visible in the check.
FOREIGN = {"_process", "_physics_process", "_process_message", "_execute_frame", "_notification",
           "is_in_tree", "try_lock", "strip", "decode_u16", "encode_u16", "get_format_pixel_size",
           "get_sample_view"}
# The corpus is wider than src/: a comment that names a GDScript method or a test script is naming
# something that exists. Only src/'s comments are read, though. It is rooted at the addon, not at
# native/ - rooting it where this file lives made `tool_settings.gd:_on_picked()` report as stale,
# because the editor scripts are one directory above.
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
    """Comment references to identifiers that exist nowhere in the addon.

    Raw string literals are deliberately *not* masked here, unlike everywhere else in this file: the
    shaders live inside them, so masking made this report every shader parameter (`p_world`,
    `p_surface_texel`, `projectionAxis`) as stale - sixteen of its first twenty-nine candidates.
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
                    # `*_sum_ms` in the cost banner is a glob over the field names that end in it,
                    # not a name, and it is the only place a leading `*` reaches this check.
                    if match.start() and body[match.start() - 1] == "*":
                        continue
                    line = first_line + body[:match.start()].count("\n")
                    hits.setdefault(name, set()).add("%s:%d" % (path.name, line))

    print("   (%d names in the corpus, %d comment references that match none)"
            % (len(code_words), len(hits)))
    report("comments naming an identifier the addon does not define",
            [(name, ", ".join(sorted(hits[name])[:4])) for name in sorted(hits)])


# A column-0 definition, and the keywords that also start a column-0 line inside a flush namespace
# body but declare nothing.
DEFINITION_HEAD = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?(?:\w+::)?([A-Za-z_]\w*)\s*\(")
NOT_A_FUNCTION = {"if", "for", "while", "switch", "return", "else", "do", "catch", "case", "break",
                  "continue", "class", "struct", "enum", "union", "typedef", "using", "template",
                  "namespace", "extern"}
PARAMETER_NAME = re.compile(r"([A-Za-z_]\w*)\s*(?:\[\s*\])?\s*$")


def code_only(text: str) -> str:
    """Text with comments and string/character literals blanked, offsets and newlines kept.

    One left-to-right pass rather than a chain of regexes, because the order matters: blanking `//`
    first turns `"http://x"` into an unterminated string, and blanking quotes first lets a comment
    that quotes something swallow the code below it.
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
            # A raw string is not a literal the other branches can read: it spans lines, so stopping
            # at the first newline left the embedded shaders in place, and the GLSL at column 0 -
            # `layout(set = 0, binding = 0)` and friends - was read as this addon's definitions.
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
    """Parameters a definition accepts and never reads.

    The compiler reports an unused parameter only under `-Wunused-parameter`, and a parameter that is
    *dropped* on the way to the call it forwards to is not reported at all - the function works, it
    just ignores what it was handed. `Terrain3DData::add_region_blankp()` was that: it took
    `p_update`, exposed it to Godot as `update`, and forwarded the location without it, so
    `add_region_blankp(pos, false)` rebuilt every map anyway. `Terrain3D::_svt_page_path()`'s `p_mip`
    is the other shape - a parameter hard-coded to 0 in the body, which is a trap for the next caller
    rather than information, and the compiler is happy with it too.
    """
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
            # A declaration ends in `;` before the brace, and the brace that follows belongs to the
            # next definition: `Layout layout(...)` was read as a function whose body was the
            # function after it, and every parameter name in it was then reported.
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
# A line continues the previous one when the previous line left a parenthesis open or ended on an
# operator. The parenthesis half alone reported every `a + b +` wrap in this tree as mis-indented.
CONTINUATION = ("+", "-", "|", "&", ",", "=", "?", ":", "\\")
BODY_HEAD = re.compile(r"^[A-Za-z_][\w:<>,*&\s]*?(?:\w+::)?([A-Za-z_]\w*)\s*\(")


def indent() -> None:
    """Mis-indented runs, and bodies whose first statement is a level too deep.

    Two checks in one pass, because one cannot see what the other does. The run check tolerates a
    line at `expected + 1` when it continues the previous one - which is right, and is exactly why it
    cannot see a body indented one level too deep: every one of its lines sits at `expected + 1`, and
    the defect reads as a wrap. `_svt_walk_visible_pages()` was written that way for fifty-one lines
    after being extracted from `_update_visible_svt()`, and the compiler has no opinion about it.

    So the second check looks at the one line with a unique expected depth, the first statement of a
    body, and the first check keeps looking everywhere else. Both are reported in file order.
    """
    runs = []
    deep = []
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
            # Part two: the first statement after a definition's opening brace. Only column-0 lines
            # reach here, so this is a definition rather than a declaration inside a class body.
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
                body_line = index + window[:body_at].count("\n") + 1
                body_expected = expected + 1
                while body_line < len(code_lines):
                    body_stripped = code_lines[body_line].strip()
                    if body_stripped and not body_stripped.startswith(("//", "#")):
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
