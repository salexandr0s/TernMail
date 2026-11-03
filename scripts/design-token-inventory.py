#!/usr/bin/env python3
"""Generate the source inventory used by docs/design. No third-party packages."""

from __future__ import annotations

import argparse
from bisect import bisect_right
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path("docs/design/design-token-inventory.json")
TEMPLATE = Path("docs/design/catalog.template.html")
CATALOG = Path("docs/design/catalog.html")
IDENT = r"[A-Za-z_][A-Za-z_0-9]*"
TYPE_RE = re.compile(rf"\b(enum|struct|class|extension)\s+({IDENT}(?:\.{IDENT})*)")
MEMBER_RE = re.compile(rf"\bstatic\s+(let|var|func)\s+({IDENT})")
CHAIN_RE = re.compile(rf"\b{IDENT}(?:\s*\.\s*{IDENT})+")
UI_BASES = re.compile(
    r"\b(View|ViewModifier|Layout|ButtonStyle|ShapeStyle|NSViewRepresentable|NSViewControllerRepresentable|"
    r"NSView|NSControl|NSTextView|NSTokenField|NSTokenFieldCell|NSCollectionViewItem|"
    r"NSCollectionView|NSTableView|NSOutlineView|NSScrollView|NSButton|NSWindow|NSPanel|"
    r"WKWebView|NSSearchField|NSTextAttachment)\b"
)
VISUAL_CALLS = {
    "font": "typography", "fontWeight": "typography", "fontDesign": "typography",
    "lineSpacing": "typography", "kerning": "typography", "tracking": "typography",
    "foregroundStyle": "color", "foregroundColor": "color", "tint": "color",
    "background": "surface", "fill": "color", "opacity": "opacity",
    "padding": "spacing", "frame": "dimension", "cornerRadius": "radius",
    "RoundedRectangle": "radius", "UnevenRoundedRectangle": "radius",
    "stroke": "border", "strokeBorder": "border", "shadow": "shadow",
    "animation": "motion", "withAnimation": "motion", "transition": "motion",
    "timingCurve": "motion", "easeInOut": "motion", "spring": "motion",
    "HStack": "spacing", "VStack": "spacing", "LazyVStack": "spacing",
    "LazyHStack": "spacing", "Grid": "spacing", "GridItem": "dimension",
    "Color": "color", "NSColor": "color", "NSFont": "typography",
    "systemFont": "typography", "preferredFont": "typography",
    "monospacedSystemFont": "typography", "boldSystemFont": "typography",
    "controlSize": "native-style", "buttonStyle": "native-style",
    "textFieldStyle": "native-style", "listStyle": "native-style",
    "pickerStyle": "native-style", "toggleStyle": "native-style",
    "symbolRenderingMode": "iconography", "imageScale": "iconography",
    "scaleEffect": "dimension", "offset": "dimension", "position": "dimension",
}
CALL_RE = re.compile(rf"\b({'|'.join(sorted(VISUAL_CALLS, key=len, reverse=True))})\s*\(")
NATIVE_RE = re.compile(
    r"\b(?:(Button|Toggle|Picker|DatePicker|ColorPicker|Slider|Stepper|TextField|"
    r"SecureField|TextEditor|List|Table|Menu|Form|GroupBox|DisclosureGroup|"
    r"ProgressView|Gauge|NavigationSplitView|TabView|ScrollView|Divider)\s*(?:\(|\{)|"
    r"(NSTextView|NSTokenField|NSButton|NSMenu|NSMenuItem|NSMenuItemBadge|NSTableView|NSCollectionView|"
    r"NSScrollView|WKWebView|NSAlert|NSOpenPanel|NSSavePanel|NSSearchField|NSVisualEffectView|NSTableColumn)\s*\()"
)
CSS_RE = re.compile(
    r"(?<![\w-])((?:background|border|font|text|outline|box-shadow|color|fill|stroke|"
    r"margin|padding|width|height|min-width|max-width|min-height|max-height|line-height|"
    r"opacity|gap|border-radius|transition|animation|letter-spacing)[\w-]*)\s*:\s*([^;{}<>\n]+)"
)
VISUAL_NAME = re.compile(
    r"color|colour|font|tint|opacity|alpha|width|height|size|radius|inset|padding|"
    r"spacing|gap|gutter|margin|stroke|border|shadow|lineHeight|lineSpacing|"
    r"duration|animation|baseline|darkLift|darkFloor|contrastSaturation|palette|"
    r"threshold|dominance|idleInterval", re.I
)


@dataclass
class Scope:
    name: str
    kind: str
    start: int
    opening: int
    end: int
    header: str
    parent: Scope | None = None

    @property
    def qualified(self) -> str:
        return f"{self.parent.qualified}.{self.name}" if self.parent else self.name


def mask_source(text: str) -> tuple[str, list[tuple[int, int]]]:
    """Keep offsets/newlines while masking nested comments and Swift string literals."""
    def string_end(start: int) -> int | None:
        match = re.match(r'(#{0,8})("""|")', text[start:])
        if not match:
            return None
        hashes, quote = match.groups()
        end_marker = quote + hashes
        cursor = start + len(match.group())
        while cursor < len(text):
            if text.startswith("\\" + hashes + "(", cursor):
                depth, cursor = 1, cursor + len(hashes) + 2
                while cursor < len(text) and depth:
                    nested_end = string_end(cursor) if text[cursor] in '#"' else None
                    if nested_end is not None:
                        cursor = nested_end
                        continue
                    if text[cursor] == "(":
                        depth += 1
                    elif text[cursor] == ")":
                        depth -= 1
                    cursor += 1
            elif text.startswith("\\" + hashes, cursor):
                cursor += len(hashes) + 2
            elif text.startswith(end_marker, cursor):
                return cursor + len(end_marker)
            else:
                cursor += 1
        return cursor

    result = list(text)
    strings = []
    i = 0
    while i < len(text):
        start = i
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < len(text) and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        else:
            end = string_end(i) if text[i] in '#"' else None
            if end is None:
                i += 1
                continue
            i = end
            strings.append((start, i))
        for index in range(start, min(i, len(text))):
            if text[index] != "\n":
                result[index] = " "
    return "".join(result), strings


class Source:
    def __init__(self, root: Path, path: Path):
        self.path = path.relative_to(root).as_posix()
        self.text = path.read_text()
        self.code, self.strings = mask_source(self.text)
        self.literal_ends = dict(self.strings)
        self.newlines = [i for i, char in enumerate(self.text) if char == "\n"]
        self.pairs = {}
        stack = []
        for i, char in enumerate(self.code):
            if char in "({[":
                stack.append((char, i))
            elif char in ")}]" and stack and stack[-1][0] == {
                ")": "(", "}": "{", "]": "["
            }[char]:
                _, opening = stack.pop()
                self.pairs[opening] = i
        self.scopes = []
        for match in TYPE_RE.finditer(self.code):
            opening = self.code.find("{", match.end())
            if opening not in self.pairs:
                continue
            scope = Scope(match[2], match[1], match.start(), opening,
                          self.pairs[opening], self.text[match.end():opening].strip())
            scope.parent = self.owner(scope.start)
            self.scopes.append(scope)

    def line(self, index: int) -> int:
        return bisect_right(self.newlines, index) + 1

    def location(self, index: int) -> dict:
        return {"source": self.path, "line": self.line(index)}

    def owner(self, index: int) -> Scope | None:
        return next((scope for scope in reversed(self.scopes)
                     if scope.opening < index < scope.end), None)

    def documentation(self, index: int) -> str:
        lines = self.text[:self.text.rfind("\n", 0, index)].splitlines()
        docs = []
        for line in reversed(lines):
            if not line.strip().startswith("///"):
                break
            docs.append(line.strip()[3:].strip())
        return " ".join(reversed(docs))

    def declaration_end(self, index: int) -> int:
        while index < len(self.code):
            if index in self.literal_ends:
                index = self.literal_ends[index]
            elif index in self.pairs:
                index = self.pairs[index] + 1
            elif self.code[index] in ";\n":
                following = self.code[index + 1:].lstrip()
                preceding = self.text[:index].rstrip()
                if following.startswith(".") or preceding.endswith(("=", ",", "+", "-", "*", "/", "??")):
                    index += 1
                else:
                    return index
            elif self.code[index] == "}":
                return index
            else:
                index += 1
        return index


def normalized(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def members(source: Source) -> list[dict]:
    result = []
    for match in MEMBER_RE.finditer(source.code):
        owner = source.owner(match.start())
        if not owner:
            continue
        # Static members belong directly to a type, never to a nested method body.
        containers = [opening for opening, end in source.pairs.items()
                      if source.code[opening] == "{" and opening < match.start() < end]
        if containers and max(containers) != owner.opening:
            continue
        end = source.declaration_end(match.end())
        declaration = source.text[match.end():end]
        code = source.code[match.end():end]
        before = source.text[source.text.rfind("\n", 0, match.start()) + 1:match.start()]
        visibility = next((word for word in ("private", "fileprivate", "public", "internal", "package")
                           if re.search(rf"\b{word}\b", before)), "internal")
        if match[1] == "func":
            opening = code.find("{")
            signature = declaration[:opening].strip() if opening >= 0 else declaration
            expression = declaration[opening:].strip() if opening >= 0 else declaration
            type_name = signature.split("->", 1)[-1].strip() if "->" in signature else "Void"
        else:
            declaration = declaration.strip()
            parts = declaration.split("=", 1)
            type_name = parts[0].removeprefix(":").strip() if declaration.startswith(":") else "inferred"
            if "{" in type_name:
                type_name = type_name.split("{", 1)[0].strip()
            expression = parts[1].strip() if len(parts) == 2 else declaration[declaration.find("{"):].strip()
            signature = None
        result.append({
            "name": f"{owner.qualified}.{match[2]}", "namespace": owner.qualified,
            "kind": "policy" if match[1] == "func" else "value", "type": type_name,
            "expression": expression, "signature": signature, "visibility": visibility,
            "documentation": source.documentation(match.start()), **source.location(match.start()),
            "_start": match.start(), "_end": end,
        })
    return result


def local_properties(source: Source) -> list[dict]:
    """Collect style-like properties and local bindings without promoting them to tokens."""
    result = []
    for match in re.finditer(rf"\b(let|var)\s+({IDENT})", source.code):
        owner = source.owner(match.start())
        if not owner or owner.qualified.startswith("Tokens"):
            continue
        end = source.declaration_end(match.end())
        declaration = source.text[match.end():end].strip()
        code = source.code[match.end():end]
        if "=" not in code and "{" not in code:
            continue
        if not VISUAL_NAME.search(match[2]) and not re.search(
            r"\b(?:Color|NSColor|Font|NSFont|CGFloat|CGSize|NSEdgeInsets)\b", declaration
        ):
            continue
        # View bodies and editor fields may contain style calls but are not style values.
        if re.match(r":\s*(?:some |any )?(?:View|Bool|String|Int|URL)\b", declaration) and not VISUAL_NAME.search(match[2]):
            continue
        equals, brace = code.find("="), code.find("{")
        split = equals if equals >= 0 and (brace < 0 or equals < brace) else brace
        # Derive offsets from the untrimmed source, then preserve the complete expression.
        tail = source.text[match.end():end]
        type_name = tail[:split].strip().removeprefix(":").strip() or "inferred"
        expression = tail[split + (1 if split == equals else 0):].strip()
        result.append({"name": f"{owner.qualified}.{match[2]}", "namespace": owner.qualified,
                       "kind": "local-value", "type": type_name, "expression": expression,
                       "review": "local-style-candidate", **source.location(match.start())})
    return result


def references(source: Source, names: set[str]) -> list[dict]:
    result = []
    for match in CHAIN_RE.finditer(source.code):
        chain = re.sub(r"\s+", "", match.group())
        owner = source.owner(match.start())
        candidates = [chain]
        if owner and owner.qualified.startswith("Tokens"):
            candidates.extend(["Tokens." + chain, owner.qualified + "." + chain,
                               chain.replace("Self.", owner.qualified + ".", 1)])
        found = None
        for candidate in candidates:
            while "." in candidate:
                if candidate in names:
                    found = candidate
                    break
                candidate = candidate.rsplit(".", 1)[0]
            if found:
                break
        if found:
            result.append({"token": found, **source.location(match.start()), "_start": match.start()})
    # Bare member references in token declarations/policies (for example duration: base).
    for scope in source.scopes:
        if not scope.qualified.startswith("Tokens"):
            continue
        for match in re.finditer(rf"\b{IDENT}\b", source.code[scope.opening + 1:scope.end]):
            offset = scope.opening + 1 + match.start()
            if source.owner(offset) != scope:
                continue
            name = scope.qualified + "." + match.group()
            if name not in names or (offset and source.code[offset - 1] == "."):
                continue
            prefix = source.code[max(0, offset - 20):offset]
            if re.search(r"\b(?:let|var|func)\s*$", prefix):
                continue
            result.append({"token": name, **source.location(offset), "_start": offset})
    return sorted(result, key=lambda item: (item["_start"], item["token"]))


def generate(root: Path) -> dict:
    paths = sorted((root / "App").rglob("*.swift"))
    paths += sorted((root / "Packages/Core/Sources/MessageContent").glob("*.swift"))
    sources = [Source(root, path) for path in paths]
    all_members = [member for source in sources for member in members(source)]
    tokens = [member for member in all_members if member["name"].startswith("Tokens.")]
    names = {token["name"] for token in tokens}
    if len(names) != len(tokens):
        raise ValueError("Duplicate token names need a schema that distinguishes overloads")
    components, visual, native, embedded, local, files = [], [], [], [], [], []
    by_name = {token["name"]: token for token in tokens}
    for token in tokens:
        token.update(references=[], usages=[])
    for source in sources:
        refs = references(source, names)
        source_tokens = [token for token in tokens if token["source"] == source.path]
        for ref in refs:
            clean = {key: value for key, value in ref.items() if not key.startswith("_") and key != "token"}
            by_name[ref["token"]]["usages"].append(clean)
        for token in source_tokens:
            token["references"] = sorted({ref["token"] for ref in refs
                                           if token["_start"] < ref["_start"] < token["_end"]
                                           and ref["token"] != token["name"]})
        for scope in source.scopes:
            bases = sorted(set(UI_BASES.findall(scope.header)))
            if bases and scope.kind != "extension":
                components.append({"name": scope.qualified, "kind": scope.kind,
                                   "bases": bases, **source.location(scope.start),
                                   "end_line": source.line(scope.end),
                                   "tokens": sorted({ref["token"] for ref in refs
                                                     if scope.start < ref["_start"] < scope.end})})
        local.extend(local_properties(source))
        local.extend({key: value for key, value in member.items() if not key.startswith("_")}
                     | {"review": "local-style-policy"} for member in all_members
                     if member["source"] == source.path and not member["name"].startswith("Tokens.")
                     and member["kind"] == "policy" and VISUAL_NAME.search(member["name"].rsplit(".", 1)[-1])
                     and re.search(r"\b(?:Color|NSColor|Font|NSFont|CGFloat|CGSize)\b", member["type"]))
        for match in CALL_RE.finditer(source.code):
            opening = source.code.find("(", match.start())
            end = source.pairs.get(opening)
            if end is None:
                continue
            expression = normalized(source.text[match.start():end + 1])
            backing = sorted({ref["token"] for ref in refs if match.start() < ref["_start"] < end})
            visual.append({"category": VISUAL_CALLS[match[1]], "api": match[1],
                           "expression": expression[:600], "truncated": len(expression) > 600,
                           "tokens": backing, "review": "token-backed" if backing else "direct-expression",
                           **source.location(match.start())})
        for match in NATIVE_RE.finditer(source.code):
            native.append({"control": match[1] or match[2], **source.location(match.start())})
        for match in re.finditer(
            rf"\b({IDENT}\.)*(font|textColor|backgroundColor|rowHeight|intercellSpacing|"
            r"contentInsets|textContainerInset|lineFragmentPadding|cornerRadius|borderWidth|"
            r"borderColor|selectedTextAttributes|defaultParagraphStyle)\s*=\s*(?!=)", source.code
        ):
            end = source.declaration_end(match.end())
            expression = normalized(source.text[match.start():end])
            backing = sorted({ref["token"] for ref in refs if match.start() < ref["_start"] < end})
            visual.append({"category": "native-property", "api": match[2],
                           "expression": expression[:600], "truncated": len(expression) > 600,
                           "tokens": backing, "review": "token-backed" if backing else "direct-expression",
                           **source.location(match.start())})
        for start, end in source.strings:
            for match in CSS_RE.finditer(source.text[start:end]):
                embedded.append({"property": match[1], "value": match[2].strip(),
                                 **source.location(start + match.start()), "review": "embedded-content-style"})
        files.append({"source": source.path, "sha256": hashlib.sha256(source.text.encode()).hexdigest(),
                      "lines": len(source.text.splitlines()), "token_references": len(refs)})
    for member in tokens:
        member.pop("_start")
        member.pop("_end")
    groups = dict(sorted(Counter(token["namespace"] for token in tokens).items()))
    return {
        "schema_version": 1,
        "scope": {"roots": ["App/**/*.swift", "Packages/Core/Sources/MessageContent/*.swift"],
                  "authority": "Swift source; this JSON is generated",
                  "regenerate": "python3 scripts/design-token-inventory.py",
                  "check": "python3 scripts/design-token-inventory.py --check"},
        "limitations": [
            "Lexical inventory, not a Swift compiler or a runtime appearance audit.",
            "Comments and string literals are excluded from Swift symbol matching; embedded CSS is scanned separately.",
            "References inside Swift string interpolation, inferred enum shorthand, type aliases, and dynamic dispatch may be absent.",
            "UI components are declarations with listed SwiftUI/AppKit base types; extensions and indirect subclasses may be absent.",
            "Visual expressions and local constants are review candidates; data geometry, native defaults, user colors, and email content require semantic review.",
            "Embedded styles retain Swift interpolation and authored values; they are not a proposed app palette.",
            "Property expressions preserve source syntax. Numeric aliases are not evaluated, and dynamic colors have no fixed hex value.",
            "All conditional compilation branches are scanned. No build-configuration availability is inferred.",
            "Usage counts are lexical references, including token-to-token references; zero does not prove dead code.",
        ],
        "counts": {"files": len(files), "tokens": len(tokens), "token_groups": groups,
                   "components": len(components), "local_visual_constants": len(local),
                   "visual_expressions": len(visual), "native_controls": len(native),
                   "embedded_styles": len(embedded)},
        "tokens": sorted(tokens, key=lambda item: item["name"]),
        "components": sorted(components, key=lambda item: (item["source"], item["line"])),
        "local_visual_constants": sorted(local, key=lambda item: (item["source"], item["line"])),
        "visual_expressions": sorted(visual, key=lambda item: (item["source"], item["line"], item["api"])), "native_controls": native,
        "embedded_styles": embedded, "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the generated inventory is stale")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.output if args.output.is_absolute() else root / args.output
    inventory = generate(root)
    rendered = json.dumps(inventory, ensure_ascii=False, indent=2) + "\n"
    template = root / TEMPLATE
    if not template.exists():
        parser.error(f"Missing catalog template: {template}")
    template_text = template.read_text()
    placeholder = "__TERN_DESIGN_INVENTORY__"
    if template_text.count(placeholder) != 1:
        parser.error("Catalog template must contain exactly one inventory placeholder")
    embedded = json.dumps(inventory, ensure_ascii=False, separators=(",", ":"))
    embedded = embedded.replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    catalog = template_text.replace(placeholder, embedded)
    outputs = {output: rendered, root / CATALOG: catalog}
    if args.check:
        stale = [path for path, value in outputs.items() if not path.exists() or path.read_text() != value]
        if stale:
            for path in stale:
                print(f"Stale design-token artifact: {path}", file=sys.stderr)
            print("Run python3 scripts/design-token-inventory.py", file=sys.stderr)
            return 1
        print(f"Design-token inventory is current ({inventory['counts']['tokens']} tokens).")
    else:
        for path, value in outputs.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        print(f"Wrote {output}: {inventory['counts']['tokens']} tokens, "
              f"{inventory['counts']['components']} components, {inventory['counts']['files']} files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
