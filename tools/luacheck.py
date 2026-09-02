"""Syntax-check every addon Lua file (excluding Libs/ and .release/) with luaparser.
Usage: python luacheck.py [repo_root]   -> exit 1 on any parse error."""
import os
import sys
from luaparser import ast

root = sys.argv[1] if len(sys.argv) > 1 else "."
bad = 0
count = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ("Libs", ".release", ".git", ".claude", "Fonts", "Textures")]
    for fn in filenames:
        if not fn.endswith(".lua"):
            continue
        path = os.path.join(dirpath, fn)
        src = open(path, encoding="utf-8").read()
        count += 1
        try:
            ast.parse(src)
        except Exception as e:  # luaparser raises SyntaxException
            bad += 1
            print(f"SYNTAX ERROR {os.path.relpath(path, root)}: {e}")
print(f"checked {count} files, {bad} with errors")
sys.exit(1 if bad else 0)
