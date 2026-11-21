#!/usr/bin/env python3
"""Enforce the repository no-comment rule with a per-file ratchet."""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tokenize


CODE_EXTENSIONS = {".swift", ".ts", ".js", ".sql", ".sh", ".py"}

REGEX_PRECEDERS = set("([{:;,=!?&|+-*%^~<>")
REGEX_KEYWORDS = {
    "return",
    "case",
    "throw",
    "in",
    "of",
    "typeof",
    "void",
    "delete",
    "new",
    "yield",
    "await",
    "else",
    "do",
}


@dataclass(frozen=True)
class CommentSpan:
    start_offset: int
    end_offset: int
    start_line: int
    end_line: int
    raw: str


def extract_swift_comments(text: str) -> list[CommentSpan]:
    comments: list[CommentSpan] = []
    n = len(text)
    i = 0
    line = 1

    def advance(k: int = 1) -> None:
        nonlocal i, line
        for _ in range(k):
            if i < n:
                if text[i] == "\n":
                    line += 1
                i += 1

    def scan_string(hashes: int, multiline: bool) -> None:
        delim = ('"""' if multiline else '"') + "#" * hashes
        interp = "\\" + "#" * hashes + "("
        esc = "\\" + "#" * hashes
        advance(hashes + (3 if multiline else 1))
        while i < n:
            if text.startswith(delim, i):
                advance(len(delim))
                return
            if text.startswith(interp, i):
                advance(len(interp))
                scan_code(stop_on_rparen=True)
                continue
            if text.startswith(esc, i):
                advance(len(esc) + 1)
                continue
            advance(1)

    def scan_code(stop_on_rparen: bool = False) -> None:
        nonlocal i, line
        paren_depth = 0
        while i < n:
            ch = text[i]
            if stop_on_rparen:
                if ch == "(":
                    paren_depth += 1
                    advance(1)
                    continue
                if ch == ")":
                    if paren_depth == 0:
                        advance(1)
                        return
                    paren_depth -= 1
                    advance(1)
                    continue
            if text.startswith("//", i):
                sl = line
                si = i
                while i < n and text[i] != "\n":
                    i += 1
                comments.append(CommentSpan(si, i, sl, sl, text[si:i]))
                continue
            if text.startswith("/*", i):
                sl = line
                si = i
                depth = 1
                advance(2)
                while i < n and depth > 0:
                    if text.startswith("/*", i):
                        depth += 1
                        advance(2)
                    elif text.startswith("*/", i):
                        depth -= 1
                        advance(2)
                    else:
                        advance(1)
                comments.append(CommentSpan(si, i, sl, line, text[si:i]))
                continue
            if ch == "#":
                j = i
                while j < n and text[j] == "#":
                    j += 1
                hashes = j - i
                if j < n and text[j] == '"':
                    multiline = text.startswith('"""', j)
                    scan_string(hashes, multiline)
                    continue
                advance(1)
                continue
            if ch == '"':
                multiline = text.startswith('"""', i)
                scan_string(0, multiline)
                continue
            advance(1)

    scan_code()
    return comments


def extract_js_comments(text: str) -> list[CommentSpan]:
    comments: list[CommentSpan] = []
    n = len(text)
    i = 0
    line = 1
    prev_sig = ""
    prev_word = ""

    def advance(k: int = 1) -> None:
        nonlocal i, line
        for _ in range(k):
            if i < n:
                if text[i] == "\n":
                    line += 1
                i += 1

    def scan_template() -> None:
        nonlocal prev_sig, prev_word
        advance(1)
        while i < n:
            if text[i] == "\\":
                advance(2)
            elif text.startswith("${", i):
                advance(2)
                scan_code(stop_on_rbrace=True)
            elif text[i] == "`":
                advance(1)
                prev_sig = "`"
                prev_word = ""
                return
            else:
                advance(1)

    def scan_code(stop_on_rbrace: bool = False) -> None:
        nonlocal i, line, prev_sig, prev_word
        brace_depth = 0
        while i < n:
            ch = text[i]
            if stop_on_rbrace:
                if ch == "{":
                    brace_depth += 1
                elif ch == "}":
                    if brace_depth == 0:
                        advance(1)
                        return
                    brace_depth -= 1
            if text.startswith("//", i):
                sl = line
                si = i
                while i < n and text[i] != "\n":
                    i += 1
                comments.append(CommentSpan(si, i, sl, sl, text[si:i]))
                continue
            if text.startswith("/*", i):
                sl = line
                si = i
                advance(2)
                while i < n and not text.startswith("*/", i):
                    advance(1)
                if text.startswith("*/", i):
                    advance(2)
                comments.append(CommentSpan(si, i, sl, line, text[si:i]))
                continue
            if ch in ('"', "'"):
                q = ch
                advance(1)
                while i < n and text[i] != q:
                    if text[i] == "\\":
                        advance(2)
                    else:
                        advance(1)
                if i < n:
                    advance(1)
                prev_sig = q
                prev_word = ""
                continue
            if ch == "`":
                scan_template()
                continue
            if ch == "/":
                if (
                    prev_sig == ""
                    or prev_sig in REGEX_PRECEDERS
                    or prev_word in REGEX_KEYWORDS
                ):
                    advance(1)
                    in_class = False
                    while i < n and text[i] != "\n":
                        if text[i] == "\\":
                            advance(2)
                        elif text[i] == "[":
                            in_class = True
                            advance(1)
                        elif text[i] == "]":
                            in_class = False
                            advance(1)
                        elif text[i] == "/" and not in_class:
                            advance(1)
                            while i < n and text[i].isalpha():
                                advance(1)
                            break
                        else:
                            advance(1)
                    prev_sig = "/"
                    prev_word = ""
                    continue
            if ch.isalpha() or ch in ("_", "$"):
                si = i
                while i < n and (text[i].isalnum() or text[i] in ("_", "$")):
                    advance(1)
                prev_word = text[si:i]
                prev_sig = "id"
                continue
            if not ch.isspace():
                prev_sig = ch
                prev_word = ""
            advance(1)

    scan_code()
    return comments


def extract_sql_comments(text: str) -> list[CommentSpan]:
    comments: list[CommentSpan] = []
    n = len(text)
    i = 0
    line = 1

    def advance(k: int = 1) -> None:
        nonlocal i, line
        for _ in range(k):
            if i < n:
                if text[i] == "\n":
                    line += 1
                i += 1

    while i < n:
        ch = text[i]
        if ch == "'":
            advance(1)
            while i < n:
                if text[i] == "'" and i + 1 < n and text[i + 1] == "'":
                    advance(2)
                elif text[i] == "'":
                    advance(1)
                    break
                else:
                    advance(1)
            continue
        if ch == '"':
            advance(1)
            while i < n:
                if text[i] == '"' and i + 1 < n and text[i + 1] == '"':
                    advance(2)
                elif text[i] == '"':
                    advance(1)
                    break
                else:
                    advance(1)
            continue
        if text.startswith("--", i):
            sl = line
            si = i
            while i < n and text[i] != "\n":
                i += 1
            comments.append(CommentSpan(si, i, sl, sl, text[si:i]))
            continue
        if text.startswith("/*", i):
            sl = line
            si = i
            depth = 1
            advance(2)
            while i < n and depth > 0:
                if text.startswith("/*", i):
                    depth += 1
                    advance(2)
                elif text.startswith("*/", i):
                    depth -= 1
                    advance(2)
                else:
                    advance(1)
            comments.append(CommentSpan(si, i, sl, line, text[si:i]))
            continue
        advance(1)
    return comments


def extract_sh_comments(text: str) -> list[CommentSpan]:
    comments: list[CommentSpan] = []
    lines = text.splitlines(keepends=True)
    offset = 0
    in_single = False
    in_double = False
    pending_heredocs: list[tuple[str, bool]] = []

    for line_no, raw_line in enumerate(lines, 1):
        line_no_nl = raw_line.rstrip("\r\n")
        if pending_heredocs:
            delim, strip_tabs = pending_heredocs[0]
            candidate = line_no_nl.lstrip("\t") if strip_tabs else line_no_nl
            if candidate == delim:
                pending_heredocs.pop(0)
            offset += len(raw_line)
            continue

        i = 0
        n = len(line_no_nl)
        while i < n:
            ch = line_no_nl[i]
            if in_single:
                if ch == "'":
                    in_single = False
                i += 1
                continue
            if in_double:
                if ch == "\\" and i + 1 < n:
                    i += 2
                    continue
                if ch == '"':
                    in_double = False
                i += 1
                continue
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == "'":
                in_single = True
                i += 1
                continue
            if ch == '"':
                in_double = True
                i += 1
                continue
            if line_no_nl.startswith("<<", i) and not line_no_nl.startswith("<<<", i):
                j = i + 2
                strip_tabs = False
                if j < n and line_no_nl[j] == "-":
                    strip_tabs = True
                    j += 1
                while j < n and line_no_nl[j] in (" ", "\t"):
                    j += 1
                if j < n and line_no_nl[j] in ("'", '"'):
                    q = line_no_nl[j]
                    j += 1
                    start = j
                    while j < n and line_no_nl[j] != q:
                        j += 1
                    delim = line_no_nl[start:j]
                    if delim:
                        pending_heredocs.append((delim, strip_tabs))
                    i = j + 1
                    continue
                if j < n and line_no_nl[j] == "\\":
                    j += 1
                start = j
                while j < n and (line_no_nl[j].isalnum() or line_no_nl[j] in ("_", "-")):
                    j += 1
                delim = line_no_nl[start:j]
                if delim:
                    pending_heredocs.append((delim, strip_tabs))
                i = max(j, i + 2)
                continue
            if ch == "#" and (i == 0 or line_no_nl[i - 1] in (" ", "\t", ";", "(", ")")):
                raw = line_no_nl[i:]
                comments.append(
                    CommentSpan(offset + i, offset + n, line_no, line_no, raw)
                )
                break
            i += 1
        offset += len(raw_line)
    return comments


def extract_py_comments(text: str) -> list[CommentSpan]:
    comments: list[CommentSpan] = []
    line_offsets = [0]
    for raw_line in text.splitlines(keepends=True):
        line_offsets.append(line_offsets[-1] + len(raw_line))
    for tok in tokenize.generate_tokens(io.StringIO(text).readline):
        if tok.type == tokenize.COMMENT:
            sl, sc = tok.start
            el, ec = tok.end
            start_off = line_offsets[sl - 1] + sc
            end_off = line_offsets[el - 1] + ec
            comments.append(CommentSpan(start_off, end_off, sl, el, tok.string))
    return comments


def is_exempt_directive(rel_path: str, span: CommentSpan) -> bool:
    raw = span.raw.strip()
    ext = Path(rel_path).suffix
    if ext in {".sh", ".py"} and span.start_line == 1 and raw.startswith("#!"):
        return True
    if Path(rel_path).name == "Package.swift" and span.start_line == 1:
        if re.match(r"^//\s*swift-tools-version:", raw):
            return True
    if ext in {".ts", ".js"} and re.match(r"^//\s*deno-lint-ignore(?:-file)?\b", raw):
        return True
    if (
        rel_path == "supabase/tests/900_released_api.test.sql"
        and span.start_line == 1
        and raw.startswith("--")
        and "for build " in raw
    ):
        return True
    return False


def extract_comments(rel_path: str, text: str) -> list[CommentSpan]:
    ext = Path(rel_path).suffix
    if ext == ".swift":
        spans = extract_swift_comments(text)
    elif ext in {".ts", ".js"}:
        spans = extract_js_comments(text)
    elif ext == ".sql":
        spans = extract_sql_comments(text)
    elif ext == ".sh":
        spans = extract_sh_comments(text)
    elif ext == ".py":
        spans = extract_py_comments(text)
    else:
        return []
    return [span for span in spans if not is_exempt_directive(rel_path, span)]


def comment_line_numbers(rel_path: str, text: str) -> list[int]:
    lines: set[int] = set()
    for span in extract_comments(rel_path, text):
        for ln in range(span.start_line, span.end_line + 1):
            lines.add(ln)
    return sorted(lines)


def list_code_files(root: Path) -> list[str]:
    git_dir = root / ".git"
    if git_dir.exists():
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            text=True,
            check=True,
        )
        candidates = set(proc.stdout.splitlines())
    else:
        candidates = {
            p.relative_to(root).as_posix()
            for p in root.rglob("*")
            if p.is_file() and ".git" not in p.parts
        }
    return sorted(
        rel
        for rel in candidates
        if Path(rel).suffix in CODE_EXTENSIONS and (root / rel).is_file()
    )


def scan_repository(root: Path) -> dict[str, list[int]]:
    counts: dict[str, list[int]] = {}
    for rel in list_code_files(root):
        text = (root / rel).read_text(encoding="utf-8")
        lines = comment_line_numbers(rel, text)
        if lines:
            counts[rel] = lines
    return counts


def load_ratchet(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError(f"Unsupported ratchet format in {path}")
    raw_files = data.get("files")
    if not isinstance(raw_files, dict):
        raise ValueError(f"Missing 'files' map in {path}")
    parsed: dict[str, int] = {}
    for rel, count in raw_files.items():
        if not isinstance(rel, str) or not isinstance(count, int) or isinstance(count, bool):
            raise ValueError(f"Invalid ratchet entry for {rel!r}")
        parsed[rel] = count
    return parsed


def save_ratchet(path: Path, files_map: dict[str, int]) -> None:
    payload = {
        "schema_version": 1,
        "files": {k: files_map[k] for k in sorted(files_map) if files_map[k] > 0},
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def verify_ratchet(
    scanned: dict[str, list[int]],
    ratchet: dict[str, int],
) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    stale: list[str] = []

    for rel, budget in sorted(ratchet.items()):
        if budget <= 0:
            stale.append(f"{rel}: ratchet entry must be > 0 (found {budget})")

    for rel, lines in sorted(scanned.items()):
        count = len(lines)
        budget = ratchet.get(rel, 0)
        if count > budget:
            preview = ", ".join(str(n) for n in lines[:10])
            suffix = ", ..." if len(lines) > 10 else ""
            if budget == 0:
                violations.append(
                    f"{rel}: {count} comment line(s) found (banned; lines: {preview}{suffix})"
                )
            else:
                violations.append(
                    f"{rel}: {count} comment line(s) exceed ratchet budget {budget} (lines: {preview}{suffix})"
                )
        elif rel in ratchet and count < budget:
            stale.append(
                f"{rel}: comment lines dropped from {budget} to {count}"
            )

    for rel, budget in sorted(ratchet.items()):
        if budget > 0 and rel not in scanned:
            stale.append(f"{rel}: comment lines dropped from {budget} to 0 (remove from ratchet)")

    return violations, stale


def print_report(root: Path, scanned: dict[str, list[int]]) -> None:
    by_section: dict[str, dict[str, int]] = defaultdict(
        lambda: {"files": 0, "comment_lines": 0, "full_lines": 0}
    )
    total_files = 0
    total_lines = 0
    total_full_lines = 0
    for rel, lines in sorted(scanned.items()):
        top = rel.split("/")[0]
        if top in {"supabase", "Modules"} and "/" in rel:
            top = "/".join(rel.split("/")[:2])
        file_lines = (root / rel).read_text(encoding="utf-8").splitlines()
        full_count = 0
        ext = Path(rel).suffix
        for ln in lines:
            stripped = file_lines[ln - 1].lstrip()
            if ext in {".swift", ".ts", ".js"} and stripped.startswith(("//", "/*", "*")):
                full_count += 1
            elif ext == ".sql" and stripped.startswith(("--", "/*", "*")):
                full_count += 1
            elif ext in {".sh", ".py"} and stripped.startswith("#"):
                full_count += 1
        by_section[top]["files"] += 1
        by_section[top]["comment_lines"] += len(lines)
        by_section[top]["full_lines"] += full_count
        total_files += 1
        total_lines += len(lines)
        total_full_lines += full_count

    for section in sorted(by_section):
        st = by_section[section]
        print(
            f"{section:28s} files={st['files']:3d}  comment_lines={st['comment_lines']:4d}  full_lines={st['full_lines']:4d}"
        )
    print(
        f"{'TOTAL':28s} files={total_files:3d}  comment_lines={total_lines:4d}  full_lines={total_full_lines:4d}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Enforce the repository no-comment rule with a per-file ratchet."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root directory.",
    )
    parser.add_argument(
        "--ratchet",
        type=Path,
        default=None,
        help="Path to the comment ratchet JSON file.",
    )
    parser.add_argument(
        "--update-ratchet",
        action="store_true",
        help="Tighten existing ratchet entries downward (never raises budgets or adds files).",
    )
    parser.add_argument(
        "--init-ratchet",
        action="store_true",
        help="Initialize the ratchet file from the current repository state.",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="Print remaining comment counts by directory and exit 0.",
    )
    parser.add_argument(
        "--list",
        metavar="PATH",
        default=None,
        help="List every non-exempt comment (file:line: text) under a relative path prefix.",
    )
    parser.add_argument(
        "--next-smallest",
        action="store_true",
        help="Rank remaining ratcheted directories from fewest comment lines to most.",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    ratchet_path = (
        args.ratchet.resolve()
        if args.ratchet is not None
        else root / "scripts" / "comment-ratchet.json"
    )

    scanned = scan_repository(root)

    if args.list is not None:
        prefix = args.list.strip("/")
        matched = [
            rel
            for rel in sorted(scanned)
            if not prefix or rel == prefix or rel.startswith(prefix + "/")
        ]
        for rel in matched:
            text = (root / rel).read_text(encoding="utf-8")
            for span in extract_comments(rel, text):
                first_line = span.raw.splitlines()[0]
                print(f"{rel}:{span.start_line}: {first_line}")
        return 0

    if args.next_smallest:
        by_dir: dict[str, int] = defaultdict(int)
        for rel, lines in scanned.items():
            parts = rel.split("/")
            if parts[0] == "HealthComp" and len(parts) >= 3:
                key = "/".join(parts[:3]) if parts[1] == "Features" else "/".join(parts[:2])
            elif parts[0] in {"supabase", "Modules"} and len(parts) >= 2:
                key = "/".join(parts[:2])
            else:
                key = parts[0]
            by_dir[key] += len(lines)
        for key, count in sorted(by_dir.items(), key=lambda kv: (kv[1], kv[0])):
            print(f"{count:5d}  {key}")
        return 0

    if args.report:
        print_report(root, scanned)
        return 0

    if args.init_ratchet:
        save_ratchet(ratchet_path, {rel: len(lines) for rel, lines in scanned.items()})
        print(
            f"Initialized {ratchet_path} with {len(scanned)} file(s), "
            f"{sum(len(v) for v in scanned.values())} comment line(s)."
        )
        return 0

    ratchet = load_ratchet(ratchet_path)
    violations, stale = verify_ratchet(scanned, ratchet)

    if args.update_ratchet:
        if violations:
            print("Refusing to raise comment ratchet:", file=sys.stderr)
            for item in violations:
                print(f"  - {item}", file=sys.stderr)
            return 1
        updated: dict[str, int] = {}
        for rel, budget in ratchet.items():
            current = len(scanned.get(rel, []))
            if 0 < current <= budget:
                updated[rel] = current
        save_ratchet(ratchet_path, updated)
        print(
            f"Updated {ratchet_path}: {len(updated)} file(s), "
            f"{sum(updated.values())} comment line(s) remaining."
        )
        return 0

    if violations:
        print("Comment ban violations:", file=sys.stderr)
        for item in violations:
            print(f"  - {item}", file=sys.stderr)
        print(
            "Delete tautology/stale comments, file GitHub issues for excuse comments, "
            "or move decision records to docs/adr/. See .claude/skills/delete-comment/SKILL.md.",
            file=sys.stderr,
        )
        return 1

    if stale:
        print("Comment ratchet can be tightened:", file=sys.stderr)
        for item in stale:
            print(f"  - {item}", file=sys.stderr)
        print(
            "Run: python3 scripts/verify-no-comments.py --update-ratchet",
            file=sys.stderr,
        )
        return 1

    print(
        f"No-comment ratchet OK ({len(ratchet)} legacy file(s), "
        f"{sum(ratchet.values())} ratcheted comment line(s) remaining)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
