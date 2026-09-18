"""Read-through helpers for the addon's GDScript half.

The companion to audit_code.py, and it exists for the same reason: the architecture pass has to answer
questions about eight thousand lines of script without reading all of them twice by eye. It is not part
of the test suite and nothing runs it.

    python audit_gd.py shape                  what each script holds, and what outgrew it
    python audit_gd.py outline <file.gd>      one script's functions, with line numbers and sizes
    python audit_gd.py dead                   functions and signals nothing references
    python audit_gd.py state                  members read but never assigned, or the other way round
    python audit_gd.py params                 parameters a body never reads
    python audit_gd.py dupes                  function bodies written more than once
    python audit_gd.py comments               comments naming identifiers that no longer exist
    python audit_gd.py indent                 indentation that mixes tabs and spaces, or skips a level

Three things about GDScript make the checks in here harder than their C++ counterparts, and each one is
the reason for a rule:

* A method can be reached without its name appearing in any expression. The engine calls `_ready()`,
  `_process()` and every `_on_*` a scene connects; `call("name")`, `has_method("name")` and
  `connect("name", ...)` reach a method through a *string*; and a property's accessor is named by the
  `var x: set = set_x` that declares it. `dead` therefore counts string literals and the addon's
  `.tscn` / `.tres` files as references, and skips anything whose name starts with `_`.
* GDScript has no unused-parameter warning either, and signal handlers are *required* to take the
  arguments their signal carries. The convention that distinguishes "unused because the signature
  requires it" from "unused because nobody checked" is the leading underscore, so `params` reports only
  parameters that are neither read nor `_`-prefixed.
* Comments are prose. `comments` checks only the three forms that are unambiguously about code - a
  backticked name, a `name()` call, and a `_private_name` - because checking every word reports the
  English language.

`dead` reports candidates, not verdicts. A function called only through `Callable` built from a
concatenated string, or only from a project outside this addon, is live and looks dead here.

What it found on the first run, and what each answer turned out to be worth:

* `dupes` reported nine functions written twice - all of them in `asset_dock.gd` and `asset_dock_45.gd`,
  the two dock versions. That is the finding this tool was written for, and it is fixed: the twelve
  duplicated functions are now `src/asset_dock_common.gd`, and this mode is empty.
* `comments` found `_input_apply` in `editor_plugin.gd` (no such method) and the commented-out
  `class EdDock` block in `asset_dock.gd`. Both are fixed; the two false-positive rules above came from
  the same run.
* `dead` found four unreferenced accessors - `DoubleSlider.get_min()` / `get_max()` / `get_step()` and
  `Terrain3DAssetDockContainer.get_entry_width()` - and they are *kept*: each is the read half of a
  setter the addon calls, on a `class_name`d widget that ships to users. Unreferenced by the addon is not
  the same as unreachable.
* `params`, `indent` and the rest of `dupes` are clean, which is itself the answer: the script half had
  not been drifting in any other way.
* `state` found `last_opened_directory` in `menu/channel_packer.gd` (read once, assigned nowhere) and two
  members that were declared and used nowhere at all, `current_region_position` in `editor_plugin.gd` and
  `setting_has_changed` in `ui.gd`. The two declarations are deleted; the first is recorded, because
  either fix - removing the read or adding the writer the line implies - changes what the dialog does.
"""
import re
import sys
from pathlib import Path

ADDON = Path(__file__).parent.parent
# `native/tests` is the pass's own suite, not the addon's script half, and its assertions and
# thresholds are frozen - so it is not audited. It *is* searched for references, because a method only
# a test calls is not dead. `extras/3rd_party` is vendored example code, not this addon's to clean.
SKIP_DIRS = ("bin", "godot-cpp", ".git", "csharp")
AUDITED_SKIP = ("bin", "godot-cpp", ".git", "csharp", "tests", "3rd_party")
# The pass's own readers are prose about the code, and their prose names what they are looking for:
# counting them as references made this file's own finding - "get_min() is unreferenced" - the reason
# get_min() stopped being reported as unreferenced.
TOOL_FILES = {"audit_gd.py", "audit_code.py", "check_scripts.py"}
GD = {}
REFERENCES = ""
for path in sorted(ADDON.rglob("*")):
    if any(part in SKIP_DIRS for part in path.parts) or path.name in TOOL_FILES:
        continue
    if path.suffix == ".gd" and not any(part in AUDITED_SKIP for part in path.parts):
        GD[path] = path.read_text(encoding="utf-8", errors="replace")
    elif path.suffix in (".tscn", ".tres", ".cfg", ".cs", ".cpp", ".h", ".glsl", ".py", ".gd"):
        # The C++ half reaches script methods through `call("name")` and `has_method("name")`, and the
        # suite reaches them directly, so both are reference sources for `dead`.
        REFERENCES += path.read_text(encoding="utf-8", errors="replace") + "\n"

FUNCTION_CEILING = 60
DEFINITION = re.compile(r"^([ \t]*)(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(")
SIGNAL = re.compile(r"^([ \t]*)signal\s+([A-Za-z_]\w*)")
CLASS = re.compile(r"^([ \t]*)class\s+([A-Za-z_]\w*)\s*:")
NAMED = re.compile(r"^(?:[ \t]*)(?:class_name|var|const|enum)\s+([A-Za-z_]\w*)")


def code_only(text: str, strings: bool = True) -> str:
    """Blank comments and string bodies, keeping every offset and newline.

    A `#` inside a string is not a comment and a quote inside a comment is not a string, so this is one
    left-to-right pass rather than two regexes in either order. With `strings=False` the string
    *contents* survive and only comments are blanked, which is how `comments` collects the names the
    code reaches through a string.
    """
    out = list(text)
    index = 0
    while index < len(text):
        char = text[index]
        if char == "#":
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            for i in range(index, end):
                out[i] = " "
            index = end
        elif char in "\"'":
            # GDScript has no escapes beyond \\ and \", and both are handled by skipping one char.
            quote = char
            index += 1
            while index < len(text):
                if text[index] == "\\":
                    if strings:
                        out[index] = " "
                    index += 2
                    continue
                if text[index] == quote or text[index] == "\n":
                    index += 1
                    break
                if strings:
                    out[index] = " "
                index += 1
        else:
            index += 1
    return "".join(out)


def indent_width(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def body_of(lines, start):
    """(first, last) line indexes of the block that `func` on line `start` owns."""
    head = indent_width(lines[start])
    last = start
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if not line.strip():
            continue
        if indent_width(line) <= head:
            break
        last = index
    return start, last


def functions(text=None):
    """(path, name, first, last) for every function in the corpus, in file order."""
    found = []
    for path, source in (GD.items() if text is None else [(None, text)]):
        lines = source.split("\n")
        for index, line in enumerate(lines):
            match = DEFINITION.match(line)
            if match:
                first, last = body_of(lines, index)
                found.append((path, match.group(2), first, last))
    return found


def symbols():
    """Every name the addon declares, so `dead` and `comments` can tell a typo from a live symbol."""
    names = set()
    for source in GD.values():
        code = code_only(source)
        names.update(re.findall(r"\bfunc\s+([A-Za-z_]\w*)", code))
        names.update(re.findall(r"\bsignal\s+([A-Za-z_]\w*)", code))
        names.update(re.findall(r"\bclass\s+([A-Za-z_]\w*)", code))
        names.update(re.findall(r"\b(?:class_name|var|const|enum)\s+([A-Za-z_]\w*)", code))
    return names


# What a comment may legitimately name without the addon declaring it: engine API, GDScript builtins and
# vocabulary that happens to be underscored. Every entry here is a false positive that was checked.
FOREIGN = {
    "call_deferred", "callv", "set_deferred", "get_node", "add_child", "queue_free", "is_instance_valid",
    "instantiate", "get_tree", "create_tween", "connect", "disconnect", "is_connected", "emit_signal",
    "has_method", "get_class", "set_script", "tr", "print_rich", "push_warning", "push_error",
    "load", "preload", "find_child", "get_children", "remove_child", "duplicate", "new",
    "set_process", "set_process_input", "set_physics_process", "get_viewport", "get_window",
    "get_editor_interface", "get_undo_redo", "get_filesystem", "get_resource_filesystem",
    "get_selected_paths", "get_current_directory", "add_undo_method", "add_do_method", "commit_action",
    "create_action", "get_theme_icon", "get_editor_theme", "get_setting", "set_setting",
    "get_project_settings", "call_group", "get_nodes_in_group", "add_to_group", "set_meta",
    "has_meta", "get_meta", "emit_changed", "get_rid", "set_instance_shader_parameter",
    "get_surface_override_material", "set_surface_override_material", "get_active_material",
    "get_meshes", "get_surface_count", "get_aabb", "get_height_range", "get_min_max", "get_regions_all",
    "_reposition_children", "_input", "_unhandled_input", "_gui_input", "_draw", "_notification",
    "_process", "_physics_process", "_ready", "_enter_tree", "_exit_tree", "_init",
    "get_data_directory", "get_region_size", "get_vertex_spacing", "get_mesh_asset", "get_texture_asset",
    "get_assets", "get_material", "get_instancer", "get_data", "get_collision", "get_plugin",
    "update_maps", "update_surface_region", "invalidate_surface_pages", "bake_svt", "get_vt_settings",
    "get_vt_pages", "get_surface_vt_page_metadata", "get_instances", "add_region_blank", "remove_region",
    "change_region_size", "change_surface_density", "set_surface_density", "get_surface_map",
    "set_surface_map", "get_maps", "set_pixel", "get_pixel", "get_region", "get_region_ptr",
    "save_image", "save_png", "get_image", "create_image", "resize_image", "get_mesh", "get_texture",
}
COMMENT_FORMS = (
    re.compile(r"`([A-Za-z_]\w*(?:\.\w+)*)(?:\(\))?`"),
    re.compile(r"\b([a-z_]\w{3,})\s*\(\)"),
    re.compile(r"\b(_[a-z]\w{3,})\b"),
)
# A backticked token is often a file, not an identifier - `Terrain3DParticles.tscn` - and taking the
# last dot-segment of one reports "tscn" as a stale name.
FILE_SUFFIXES = (".gd", ".tscn", ".tres", ".res", ".cfg", ".json", ".md", ".glsl", ".gdshader",
                 ".cpp", ".h", ".py", ".png", ".svg", ".import")


def report(title, entries):
    print("== " + title)
    if not entries:
        print("   (none)")
        return
    for name, detail in entries:
        print("   %-44s %s" % (name, detail))


def shape():
    print("   files by size")
    rows = sorted(((len(t.split("\n")) - 1, p.relative_to(ADDON).as_posix()) for p, t in GD.items()),
                  reverse=True)
    for lines, name in rows[:14]:
        count = sum(1 for p, _, _, _ in functions() if p and p.relative_to(ADDON).as_posix() == name)
        print("      %4d lines  %3d funcs  %s" % (lines, count, name))
    print("   functions over %d lines" % FUNCTION_CEILING)
    long = [(n, "%d lines  %s" % (last - first + 1, p.relative_to(ADDON).as_posix()))
            for p, n, first, last in functions() if last - first + 1 > FUNCTION_CEILING]
    report("long functions", sorted(long, key=lambda e: -int(e[1].split()[0])))


def outline(name):
    for path, source in GD.items():
        if path.name != name and path.relative_to(ADDON).as_posix() != name:
            continue
        lines = source.split("\n")
        classes = []
        for index, line in enumerate(lines):
            match = CLASS.match(line)
            if match:
                classes.append((indent_width(line), match.group(2)))
            func = DEFINITION.match(line)
            if func:
                while classes and classes[-1][0] >= indent_width(line):
                    classes.pop()
                _, last = body_of(lines, index)
                owner = classes[-1][1] if classes else ""
                print("%5d-%4d  %4d  %s%s" % (index + 1, last + 1, last - index + 1,
                                              owner + "." if owner else "", func.group(2)))
        return
    print("no such script: %s" % name)


def dead():
    code = {p: code_only(t) for p, t in GD.items()}
    defined = []
    for path, source in GD.items():
        lines = source.split("\n")
        for index, line in enumerate(lines):
            for regex, kind in ((DEFINITION, "func"), (SIGNAL, "signal")):
                match = regex.match(line)
                if match:
                    defined.append((path, match.group(2), kind))
                    break
    entries = []
    for path, name, kind in defined:
        if name.startswith("_"):
            continue
        outside = 0
        for other, text in code.items():
            occurrences = len(re.findall(r"\b" + re.escape(name) + r"\b", text))
            if other == path:
                occurrences -= 1  # its own declaration
            outside += occurrences
        outside += len(re.findall(r"\b" + re.escape(name) + r"\b", REFERENCES))
        outside += len(re.findall(r"[\"']" + re.escape(name) + r"[\"']", "".join(GD.values())))
        if outside == 0:
            entries.append((name, "%s, %s, no reference outside its declaration"
                            % (kind, path.relative_to(ADDON).as_posix())))
    report("functions and signals nothing references", sorted(entries))


VARIABLE = re.compile(r"^([ \t]*)(?:@\w+\s+)*var\s+([A-Za-z_]\w*)")
ASSIGNMENT = re.compile(r"\s*(?:[-+*/%&|^]|\*\*)?=(?!=)")


def state():
    """Class members that are read but never assigned, assigned but never read, or used nowhere.

    `last_opened_directory` in `menu/channel_packer.gd` is the case this exists for: it is read once
    (to set a file dialog's path) and written nowhere, so the only thing that line can do is reset the
    dialog. The C++ half's `dead` mode reports the same class of finding for member fields.

    Three rules, each of which suppresses a class of false positive rather than reporting it:

    * Only column-0 `var`s are members; an indented `var` is a local, and a local's assignment is its
      own declaration, which this walk skips.
    * The search is over the whole corpus, because a member declared in a base script is written by the
      subclass that extends it - `asset_dock_common.gd` declares `_confirmed` and only the two docks
      assign it.
    * A name followed by `.` counts as both a read and a write, because a collection is filled by
      `push_back()` rather than by `=`; a name appearing inside a string literal counts as both too,
      because a property can be reached by path - `tween_property(self, "editor_decal_fade", ...)` is
      what uses `ui_decal.gd`'s fade field. An `@export` is assigned by the inspector, so it is skipped.
      That under-reports (a shadowed name looks used) and never over-reports.
    """
    code = {path: code_only(text) for path, text in GD.items()}
    lines_by_path = {path: text.split("\n") for path, text in code.items()}
    raw_by_path = {path: text.split("\n") for path, text in GD.items()}
    entries = []
    for path, lines in lines_by_path.items():
        for index, line in enumerate(raw_by_path[path]):
            match = VARIABLE.match(line)
            if not match or indent_width(line) != 0 or "@export" in line:
                continue
            name = match.group(2)
            writes = 1 if ASSIGNMENT.search(line[match.end():]) else 0
            reads = 0
            for other_path, other_lines in lines_by_path.items():
                for number, other in enumerate(other_lines):
                    if other_path == path and number == index:
                        continue
                    for hit in re.finditer(r"\b" + re.escape(name) + r"\b", other):
                        if other[hit.end():hit.end() + 1] == ".":
                            writes += 1
                            reads += 1
                        elif ASSIGNMENT.match(other[hit.end():]):
                            writes += 1
                        else:
                            reads += 1
            where = "%s:%d" % (path.relative_to(ADDON).as_posix(), index + 1)
            if re.search(r"[\"']" + re.escape(name) + r"[\"']", raw_by_path[path][index]):
                continue
            quoted = any(re.search(r"[\"']" + re.escape(name) + r"[\"']", text) for text in GD.values())
            if quoted:
                continue
            if writes == 0 and reads == 0:
                entries.append((name, "declared and never used  " + where))
            elif writes == 0:
                entries.append((name, "read %d time(s), never assigned  %s" % (reads, where)))
            elif reads == 0:
                entries.append((name, "assigned %d time(s), never read  %s" % (writes, where)))
    report("members with only one side", sorted(entries))


def params():
    entries = []
    for path, source in GD.items():
        lines = source.split("\n")
        for index, line in enumerate(lines):
            match = DEFINITION.match(line)
            if not match:
                continue
            # A signature may continue on the next lines until the argument list closes.
            signature = line
            cursor = index
            depth = line.count("(") - line.count(")")
            while depth > 0 and cursor + 1 < len(lines):
                cursor += 1
                signature += " " + lines[cursor]
                depth += lines[cursor].count("(") - lines[cursor].count(")")
            arguments = signature[signature.index("(") + 1:signature.rindex(")")]
            first, last = body_of(lines, index)
            body = code_only("\n".join(lines[first:last + 1]))
            for argument in arguments.split(","):
                argument = argument.strip()
                if not argument or ":" not in argument and "=" not in argument:
                    continue
                name = re.split(r"[:=]", argument)[0].strip()
                if not name.isidentifier() or name.startswith("_"):
                    continue
                if not re.search(r"\b" + re.escape(name) + r"\b", body):
                    entries.append((match.group(2) + "(" + name + ")",
                                    path.relative_to(ADDON).as_posix() + ":%d" % (index + 1)))
    report("parameters a body never reads", sorted(set(entries)))


def dupes(minimum=6):
    seen = {}
    for path, name, first, last in functions():
        lines = GD[path].split("\n")[first:last + 1]
        body = code_only("\n".join(lines))
        body = "\n".join(l.strip() for l in body.split("\n") if l.strip() and not l.strip().startswith("#"))
        if body.count("\n") + 1 < minimum:
            continue
        seen.setdefault(body, []).append("%s:%s" % (path.relative_to(ADDON).as_posix(), name))
    report("function bodies written more than once",
           [(names[0].split(":")[1], ", ".join(names)) for names in seen.values() if len(names) > 1])


def comments():
    words = set()
    for path in ADDON.rglob("*"):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix in (".gd", ".tscn", ".tres", ".cfg", ".cs", ".cpp", ".h"):
            text = path.read_text(encoding="utf-8", errors="replace")
            words.update(re.findall(r"[A-Za-z_]\w*", code_only(text)))
            # A name the code reaches by string is still a name the addon contains: a node name
            # (`TransformChangedSignaller`), a property path (`tween_property(self, "editor_decal_fade")`)
            # or a `call()` target. String contents only, never the surrounding comments - otherwise one
            # comment naming a dead identifier would teach the check that the identifier exists.
            for literal in re.findall(r"\"([^\"\n]*)\"|'([^'\n]*)'", code_only(text, strings=False)):
                words.update(re.findall(r"[A-Za-z_]\w*", literal[0] + literal[1]))
    entries = []
    for path, source in GD.items():
        for number, line in enumerate(source.split("\n"), 1):
            if "#" not in line:
                continue
            body = line[line.index("#"):]
            for regex in COMMENT_FORMS:
                for match in regex.finditer(body):
                    token = match.group(1)
                    if token.endswith(FILE_SUFFIXES):
                        continue
                    # Prose emphasis - "changes its transform _after_ reparenting it" - is not a name:
                    # no identifier ends with an underscore.
                    if token.endswith("_"):
                        continue
                    name = token.split(".")[-1]
                    if name in words or name in FOREIGN:
                        continue
                    entries.append((name, "%s:%d" % (path.relative_to(ADDON).as_posix(), number)))
    report("comments naming an identifier the corpus does not contain", sorted(set(entries)))


def indent():
    mixed = []
    for path, source in GD.items():
        lines = source.split("\n")
        tabs = sum(1 for l in lines if l.startswith("\t"))
        spaces = sum(1 for l in lines if l.startswith(" "))
        if tabs and spaces:
            mixed.append((path.relative_to(ADDON).as_posix(), "%d tab-indented, %d space-indented" % (tabs, spaces)))
        for number, line in enumerate(lines, 1):
            if re.match(r"^ +\t", line) or re.match(r"^\t+ +\S", line):
                mixed.append((path.relative_to(ADDON).as_posix() + ":%d" % number,
                              "indent mixes tabs and spaces: %r" % line[:40]))
    report("files mixing tabs and spaces, and lines that mix them mid-indent", sorted(set(mixed)))


if __name__ == "__main__":
    modes = {"shape": shape, "dead": dead, "params": params, "dupes": dupes, "state": state,
             "comments": comments, "indent": indent}
    if len(sys.argv) < 2 or (sys.argv[1] not in modes and sys.argv[1] != "outline"):
        print(__doc__)
    elif sys.argv[1] == "outline":
        outline(sys.argv[2])
    else:
        modes[sys.argv[1]]()
