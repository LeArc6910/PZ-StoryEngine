"""모드 Lua 테스트 실행기 (lupa, Lua 5.1).

    python tests/run_lua_tests.py            # 전부
    python tests/run_lua_tests.py life       # 이름에 life 가 들어간 테스트만

tests/lua/test_*.lua 는 { 이름 = 함수 } 표를 돌려준다. 테스트마다 새 Lua 환경에서
harness.lua -> H.boot()(모든 서버 모듈 로드) -> 테스트 파일 순으로 불러와 실행한다.
그 전에 모드의 모든 .lua 파일을 문법 검사한다.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

from lupa import lua51

REPO = Path(__file__).resolve().parents[1]
LUA_ROOT = REPO / "mod" / "StoryEngine" / "42" / "media" / "lua"
TESTS = Path(__file__).resolve().parent / "lua"


def read_mod(rel: str) -> str | None:
    p = LUA_ROOT / rel
    return p.read_text(encoding="utf-8") if p.is_file() else None


def syntax_errors() -> list[str]:
    lua = lua51.LuaRuntime()
    check = lua.eval("function(src, name) local f, err = loadstring(src, name); return err end")
    errors = []
    for f in sorted(LUA_ROOT.rglob("*.lua")):
        err = check(f.read_text(encoding="utf-8"), "@" + f.relative_to(LUA_ROOT).as_posix())
        if err:
            errors.append(str(err))
    return errors


def mod_file_errors() -> list[str]:
    """게임이 읽는 모드 파일 점검 (2026-10-01).

    * sandbox-options.txt: 바닐라 파서(CustomSandboxOptions)는 맨 위에 VERSION 과 option 블록만 받는다.
      주석 한 줄("--")만 있어도 "unknown block type" 으로 파일 전체를 버린다 (42.21 확인).
      옵션마다 KO/EN Sandbox.json 에 이름·설명(_tooltip), enum 은 _option1..N, 페이지 제목이 있어야 한다.
    * server/ 의 모든 .lua 는 클라이언트에서도 불러와지므로 "if isClient() then return end" 가 있어야 한다.
    """
    import json
    import re
    errors: list[str] = []
    media = LUA_ROOT.parent
    text = (media / "sandbox-options.txt").read_text(encoding="utf-8")
    tr = {lang: json.loads((LUA_ROOT / "shared" / "Translate" / lang / "Sandbox.json").read_text(encoding="utf-8"))
          for lang in ("KO", "EN")}
    pos = 0
    token = re.compile(r"\s*(VERSION\s*=\s*\d+\s*,|option\s+([A-Za-z0-9_.]+)\s*\{([^}]*)\})", re.S)
    pages = set()
    while pos < len(text.rstrip()):
        m = token.match(text, pos)
        if not m:
            errors.append("sandbox-options.txt: unknown block near: " + text[pos:pos + 40].strip().splitlines()[0])
            break
        pos = m.end()
        if not m.group(2):
            continue
        name, body = m.group(2), m.group(3)
        fields = {}
        for part in body.split(","):
            if part.strip():
                if "=" not in part:
                    errors.append(f"sandbox-options.txt: {name}: bad field {part.strip()!r}")
                    continue
                k, v = part.split("=", 1)
                fields[k.strip()] = v.strip()
        for need in ("type", "page", "translation"):
            if need not in fields:
                errors.append(f"sandbox-options.txt: {name}: missing {need}")
        pages.add(fields.get("page"))
        key = "Sandbox_" + fields.get("translation", "")
        for lang, d in tr.items():
            for k in (key, key + "_tooltip"):
                if k not in d:
                    errors.append(f"Sandbox.json {lang}: missing {k}")
            if fields.get("type") == "enum":
                vt = "Sandbox_" + fields.get("valueTranslation", "")
                for i in range(1, int(fields.get("numValues", "0")) + 1):
                    if f"{vt}_option{i}" not in d:
                        errors.append(f"Sandbox.json {lang}: missing {vt}_option{i}")
    for page in pages:
        for lang, d in tr.items():
            if page and "Sandbox_" + page not in d:
                errors.append(f"Sandbox.json {lang}: missing page title Sandbox_{page}")
    for f in sorted((LUA_ROOT / "server").rglob("*.lua")):
        if "if isClient() then return end" not in f.read_text(encoding="utf-8"):
            errors.append(f"{f.relative_to(LUA_ROOT)}: no 'if isClient() then return end' (server files load on clients too)")
    return errors


def client_modules() -> list[str]:
    base = LUA_ROOT / "client"
    return sorted("StoryEngine/" + f.stem for f in (base / "StoryEngine").glob("*.lua"))


def new_runtime():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().PY_READ = read_mod
    lua.globals().PY_LIST_CLIENT = lambda: lua.table_from(client_modules())
    lua.execute((TESTS / "harness.lua").read_text(encoding="utf-8"))
    return lua


RUN_ONE = """
function(src, chunkname, name)
    local chunk, err = loadstring(src, chunkname)
    if not chunk then return false, err end
    local suite = chunk()
    -- __client = true 인 테스트 파일은 클라이언트 모듈을 불러온다
    local okBoot, bootErr = xpcall(suite.__client and H.bootClient or H.boot, debug.traceback)
    if not okBoot then return false, bootErr end
    local fn = suite[name]
    local ok, msg = xpcall(fn, debug.traceback)
    return ok, msg
end
"""

NAMES = """
function(src, chunkname)
    local suite = assert(loadstring(src, chunkname))()
    local out = {}
    for k, v in pairs(suite) do
        if type(v) == "function" then out[#out + 1] = k end
    end
    table.sort(out)
    return table.concat(out, ",")
end
"""


def collect(filter_text: str = "") -> list[tuple[Path, str]]:
    cases = []
    for f in sorted(TESTS.glob("test_*.lua")):
        src = f.read_text(encoding="utf-8")
        lua = new_runtime()
        names = lua.eval(NAMES)(src, "@" + f.name)
        for name in str(names).split(","):
            if name and filter_text in f"{f.stem}.{name}":
                cases.append((f, name))
    return cases


def run_case(f: Path, name: str) -> tuple[bool, str, list[str]]:
    lua = new_runtime()
    ok, msg = lua.eval(RUN_ONE)(f.read_text(encoding="utf-8"), "@" + f.name, name)
    unknown = sorted(str(k) for k in lua.globals().H.unknown.keys())
    return bool(ok), str(msg or ""), unknown


def main(argv: list[str]) -> int:
    errors = syntax_errors() + mod_file_errors()
    for e in errors:
        print("SYNTAX", e)
    filter_text = argv[1] if len(argv) > 1 else ""
    cases = collect(filter_text)
    failed = 0
    for f, name in cases:
        try:
            ok, msg, _ = run_case(f, name)
        except Exception:
            ok, msg = False, traceback.format_exc()
        print(("ok   " if ok else "FAIL ") + f"{f.stem}.{name}")
        if not ok:
            failed += 1
            print("     " + msg.replace("\n", "\n     "))
    print(f"{len(cases)} tests, {failed} failed, {len(errors)} syntax errors")
    return 1 if failed or errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
