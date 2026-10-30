#!/usr/bin/env python3
"""Repair XcodeGen's missing backlink for the local BuildSightKit product.

Xcode.app requires XCSwiftPackageProductDependency.package to point at its
XCLocalSwiftPackageReference. XcodeGen currently omits that field for local
packages; xcodebuild can still resolve by product name, masking the problem.
"""

from pathlib import Path
import re
import sys

project = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "BuildSight.xcodeproj/project.pbxproj"
source = project.read_text()

reference = re.search(
    r'([A-F0-9]{24}) /\* XCLocalSwiftPackageReference "Packages/BuildSightKit" \*/ = \{',
    source,
)
if reference is None:
    raise SystemExit("BuildSightKit local package reference is missing")

begin = source.index("/* Begin XCSwiftPackageProductDependency section */")
end = source.index("/* End XCSwiftPackageProductDependency section */", begin)
section = source[begin:end]
block = re.compile(
    r'(?P<head>^\t\t[A-F0-9]{24} /\* BuildSightKit \*/ = \{\n)'
    r'(?P<body>(?:^\t\t\t.*\n)*)'
    r'(?P<tail>^\t\t\};)',
    re.MULTILINE,
)
found = 0
changed = 0

def link(match: re.Match[str]) -> str:
    global found, changed
    body = match.group("body")
    if "productName = BuildSightKit;" not in body:
        return match.group(0)
    found += 1
    if "package = " in body:
        return match.group(0)
    backlink = f'\t\t\tpackage = {reference.group(1)} /* XCLocalSwiftPackageReference "Packages/BuildSightKit" */;\n'
    body = body.replace("\t\t\tisa = XCSwiftPackageProductDependency;\n", "\t\t\tisa = XCSwiftPackageProductDependency;\n" + backlink, 1)
    changed += 1
    return match.group("head") + body + match.group("tail")

section = block.sub(link, section)
if found != 2:
    raise SystemExit(f"Expected 2 BuildSightKit product dependencies, found {found}")
if changed:
    project.write_text(source[:begin] + section + source[end:])
print(f"BuildSightKit package references: {found} linked, {changed} repaired")
