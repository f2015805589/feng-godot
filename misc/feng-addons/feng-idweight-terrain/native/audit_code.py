"""Read-through helpers for the addon's own source.

Not part of the test suite and not run by anything: this is the tool the architecture pass uses to
answer three questions mechanically instead of by eye, so the answers do not depend on reading thirty
thousand lines carefully.

    python audit_code.py dead                    declarations nothing in src/ references
    python audit_code.py shape                   what each file holds, and what outgrew it
    python audit_code.py structure <function>    one function's top-level statements

`dead` is what found the experimental distance-mip controls and the unused `get_warnings()` accessor:
a symbol that appears only where it is declared is dead, while a symbol used from an inline accessor
in the same header, or named by an `ADD_PROPERTY` binding string, is not - so the binding names are
part of the search. It reports candidates, not verdicts: a property getter named only from its
binding is live, and the report says which case each candidate is.

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


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "dead"
    if what == "dead":
        dead()
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
