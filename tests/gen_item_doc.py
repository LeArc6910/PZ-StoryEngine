"""게임·모드 아이템 스크립트와 인게임 분류 결과(itempool.txt)로 docs/ITEM_CATEGORIES.md 의 목록 부분을 다시 만든다.
사용: python tests/gen_item_doc.py   (문서에서 목록 앞부분은 그대로 두고 뒤를 바꾼다)
경로(게임·창작마당·모드 목록)는 개발 PC 기준. 모드 구성이 바뀌면 MEDIA 목록과, 인게임 디버그 "아이템 분류"로 만든 itempool.txt 를 갱신한다.
규칙은 mod/.../shared/StoryEngine/Value.lua, ItemPool.lua 와 같게 맞춘다 (2026-09-30 도구·기호품 좁힘 반영)."""
import json, os, re, sys, pathlib, collections

GAME = pathlib.Path(r"E:/SteamLibrary/steamapps/common/ProjectZomboid/media")
WS = pathlib.Path(r"E:/SteamLibrary/steamapps/workshop/content/108600")
MOD = pathlib.Path(r"K:/모드 개발/프로젝트 좀보이드/ai 모드/mod/StoryEngine/42/media")
POOL = pathlib.Path(os.path.expanduser("~")) / "Zomboid/Lua/StoryEngine/itempool.txt"


def version_dirs(mod_root):
    out = [d for d in mod_root.iterdir() if d.is_dir() and (d / "media").exists()]

    def key(d):
        m = re.match(r"(\d+)(?:\.(\d+))?", d.name)
        return (int(m.group(1)), int(m.group(2) or 0)) if m else (-1, 0)
    vers = sorted([d for d in out if re.match(r"\d", d.name) and key(d) <= (42, 20)], key=key)
    chosen = [d for d in out if d.name == "common"]
    if vers:
        chosen.append(vers[-1])
    return [d / "media" for d in chosen]


MEDIA = [("vanilla", GAME), ("StoryEngine", MOD)]
for label, root in (("VFE", WS / "3577903007/mods/Vanilla Foods Expanded"),
                    ("MFS", WS / "3633421539/mods/Escape from Kentucky4215"),
                    ("A-Life", WS / "3803984183/mods/ProjectALifeNPCs")):
    for m in version_dirs(root):
        MEDIA.append((label, m))

items = {}
alcohol_fluids = set()
for label, media in MEDIA:
    for f in (media / "scripts").rglob("*.txt"):
        text = f.read_text(encoding="utf-8", errors="replace")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        for m in re.finditer(r"\bfluid\s+(\w+)\s*\{(.*?)\n    \}", text, flags=re.S):
            a = re.search(r"alcohol\s*=\s*([\d\.]+)", m.group(2))
            if a and float(a.group(1)) > 0:
                alcohol_fluids.add(m.group(1))
        module, depth, cur, cur_depth, entered = None, 0, None, None, False
        for raw in text.splitlines():
            line = raw.split("//")[0].strip()
            if not line:
                continue
            m = re.match(r"module\s+(\w+)", line)
            if m and depth == 0:
                module = m.group(1)
            m = re.match(r"item\s+([\w\-]+)", line)
            if m and module and cur is None and depth == 1:
                cur = module + "." + m.group(1)
                items[cur] = {"cat": None, "obsolete": False, "src": label, "ranged": False, "ammo": False,
                              "weight": 1.0, "fluids": [], "alcoholic": False}
                cur_depth, entered = depth, False
            if cur:
                m = re.match(r"fluid\s*=\s*([\w\.]+)", line)
                if m:
                    items[cur]["fluids"].append(m.group(1).split(".")[-1])
            if cur and depth == cur_depth + 1:
                info = items[cur]
                m = re.match(r"DisplayCategory\s*=\s*(\w+)", line)
                if m:
                    info["cat"] = m.group(1)
                m = re.match(r"Weight\s*=\s*([\d\.]+)", line)
                if m:
                    info["weight"] = float(m.group(1))
                if re.match(r"(?i)alcoholic\s*=\s*true", line):
                    info["alcoholic"] = True
                if re.match(r"(?i)ranged\s*=\s*true", line):
                    info["ranged"] = True
                if re.match(r"(?i)ammoType\s*=", line):
                    info["ammo"] = True
                if re.match(r"(?i)(obsolete|hidden)\s*=\s*true", line):
                    info["obsolete"] = True
            depth += line.count("{") - line.count("}")
            if cur and depth > cur_depth:
                entered = True
            if cur and entered and depth <= cur_depth:
                cur, cur_depth, entered = None, None, False

names = {}
for label, media in MEDIA:
    for f in (media / "lua/shared/Translate/KO").glob("ItemName*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        for k, v in data.items():
            names[k] = v


def nm(ft):
    n = names.get(ft) or names.get("ItemName_" + ft)
    return f"{n} `{ft}`" if n else f"`{ft}`"


pool = collections.defaultdict(dict)
guns, ammo_role = {}, {}
cur = None
for line in POOL.read_text(encoding="utf-8").splitlines():
    m = re.match(r"\[(\w+) (\d)\] \d+", line)
    if m:
        cur = (m.group(1), int(m.group(2)))
        pool[cur[0]][cur[1]] = []
        continue
    if cur and line.startswith("  "):
        body = line.strip()
        if cur[0] == "firearm":
            m = re.match(r"(\S+)\s+round=(\S+) box=(\S+) mag=(\S+)", body)
            if m:
                ft = m.group(1)
                pool["firearm"][cur[1]].append(ft)
                guns[ft] = m.groups()[1:]
                ammo_role[m.group(2)] = "round"
                if m.group(3) != "nil":
                    ammo_role[m.group(3)] = "box"
                if m.group(4) != "nil":
                    ammo_role[m.group(4)] = "mag"
        else:
            pool[cur[0]][cur[1]].extend(x.strip() for x in body.split(",") if x.strip())

in_pool = {ft for c in pool.values() for lst in c.values() for ft in lst}
melee_pool = {ft for lst in pool["melee"].values() for ft in lst}

TOOL_NOT = ["Debug", "Mold", "Unfired", "Parts", "SeedPaste", "Tobacco"]
SPECIAL = {"Base.PipeWrench": 20, "Base.WoodAxe": 20, "Base.Sledgehammer": 20, "Base.Sledgehammer2": 20,
           "Base.BlowTorch": 20, "Base.Axe": 10, "Base.WeldingMask": 20, "Base.OilPress": 20,
           "Base.SheepElectricShears": 20, "Base.HeavyChain": 8, "Base.HeavyChain_Hook": 8, "Base.CrudeBenchVise": 8}
MORALE_SPECIAL = {"Base.Battery", "Base.Candle", "Base.CigaretteCarton", "Base.CigarettePack", "Base.CigaretteSingle",
                  "Base.CigaretteRolled", "Base.TobaccoDried"}

# 분류 이름 -> 종류 (게임 ItemPool.CATEGORY_KINDS 와 같게)
CATEGORY_KINDS = {
    "tools": ["tool", "tools", "toolweapon", "toolkit", "hardware"],
    "medical": ["firstaid", "firstaidweapon", "bandage", "medical", "medicine", "medic", "medkit", "pharmacy",
                "health", "healthcare"],
    "explosive": ["explosives", "explosive", "bomb", "bombs", "grenade", "grenades"],
    "melee": ["weapon", "melee", "meleeweapon", "weaponmelee", "sportsweapon", "gardeningweapon", "materialweapon",
              "weaponcrafted", "blade", "blades", "blunt"],
    "ammo": ["ammo", "ammunition"],
    "literature": ["literature", "book", "books", "magazine", "magazines", "reading"],
    "vehicle": ["vehiclemaintenance", "vehiclemaintenanceweapon", "vehicle", "vehicleparts", "carparts", "carpart",
                "autoparts"],
}
KIND_OF = {n: k for k, names in CATEGORY_KINDS.items() for n in names}


def kind(dc):
    return KIND_OF.get((dc or "").lower())


groups = collections.defaultdict(list)
tool_value, tool_in_melee = {}, set()
for ft, info in sorted(items.items()):
    if info["obsolete"]:
        continue
    dc = info["cat"] or ""
    short = ft.split(".", 1)[1]
    if kind(dc) == "tools":
        if not any(w in short for w in TOOL_NOT):
            groups["tools"].append(ft)
            w = info["weight"]
            tool_value[ft] = SPECIAL.get(ft) or (2 if w < 0.3 else 20 if w >= 5 else 8)
            if ft in melee_pool:
                tool_in_melee.add(ft)
    elif ft in in_pool:
        pass
    elif kind(dc) == "ammo" or ft in ammo_role:
        groups["ammo"].append(ft)
    elif info["ranged"] or (dc in ("Weapon", "FireArm") and info["ammo"]):
        groups["gun_other"].append(ft)
    elif kind(dc) == "explosive":
        groups["explosive"].append(ft)
    elif kind(dc) == "medical":
        groups["medical"].append(ft)
    elif kind(dc) == "melee":
        groups["melee_other"].append(ft)
    if kind(dc) == "vehicle":
        groups["vehicle"].append(ft)
    alcohol = dc == "Food" and ft not in in_pool and (
        info["alcoholic"] or any(fl in alcohol_fluids for fl in info["fluids"]))
    tobacco = dc == "Junk" and any(short.startswith(p) for p in ("Cigarette", "Cigar", "Tobacco"))
    if ft in MORALE_SPECIAL or kind(dc) == "literature" or tobacco or alcohol:
        groups["morale"].append(ft)

out = []


def section(title, lst, note=None):
    out.append(f"### {title} ({len(lst)})\n")
    if note:
        out.append(note + "\n")
    out.append(", ".join(nm(ft) for ft in lst) + "\n")


out.append("## 분류별 목록\n")
out.append("### 총기 (등급 = 쓰는 탄약)\n")
out.append("가치 30/40/50/65/80. 탄창 20발 이상 자동화기는 5등급.\n")
for t in sorted(pool["firearm"]):
    lst = pool["firearm"][t]
    out.append(f"**{t}등급 ({len(lst)})**: " + ", ".join(f"{nm(ft)} (탄: {nm(guns[ft][0])})" for ft in lst) + "\n")
if groups["gun_other"]:
    section("총기 (등급 없음, 가치 50)", groups["gun_other"],
            "원거리 무기지만 등급 풀에서 빠진 것: .50 BMG·14.5mm·유탄·화염 연료를 쓰거나, 탄약이 탄약 분류가 아니거나, "
            "장난감 총. 대가로는 총기로 받지만 보상·거래 상품으로는 나오지 않는다")
section("탄약", groups["ammo"],
        "낱발 0.5 · 탄창 5 · 상자 15 · 카턴 60. 총이 가리키는 낱발·상자·탄창과 DisplayCategory `Ammo`")
out.append("### 근접 무기 (등급 = 피해 순위)\n")
out.append("피해 순위 5분위로 등급. 가치 3/4/5/8/12 (카타나 12, 마체테 10 등 예외). "
           "무기 겸 도구(`ToolWeapon`: 망치·렌치·도끼 등)는 보상으로는 근접 무기로 나오지만 거래·물자 지원에서는 도구라서 아래 도구 목록에 있다\n")
for t in sorted(pool["melee"]):
    lst = [ft for ft in pool["melee"][t] if ft not in tool_in_melee]
    out.append(f"**{t}등급 ({len(lst)})**: " + ", ".join(nm(ft) for ft in lst) + "\n")
if groups["melee_other"]:
    section("근접 무기 (등급 풀 밖, 가치 5)", groups["melee_other"],
            "DisplayCategory `Weapon` 이지만 피해가 너무 낮아 등급 풀에 안 들어간 것")
out.append(f"### 도구 ({len(groups['tools'])})\n")
out.append("DisplayCategory `Tool`·`ToolWeapon`. 이름에 Debug·Mold·Unfired·Parts·SeedPaste·Tobacco 가 들어간 것은 도구가 아니다. "
           "가치는 무게로 0.3kg 미만 2, 5kg 이상 20, 그 밖 8 (예외: 대형망치·파이프렌치·장작 도끼·토치·용접 마스크·기름 압착기·"
           "전기 양털 가위 20, 도끼 10, 쇠사슬·벤치 바이스 8)\n")
for v in (20, 10, 8, 2):
    lst = [ft for ft in groups["tools"] if tool_value[ft] == v]
    if lst:
        out.append(f"**가치 {v} ({len(lst)})**: " + ", ".join(nm(ft) for ft in lst) + "\n")
section("의약품", groups["medical"],
        "DisplayCategory `FirstAid`·`FirstAidWeapon`·`Bandage`. 가치 3, 항생제 8, 봉합 바늘·소독약 4, 부목 3")
section("폭발물", groups["explosive"], "DisplayCategory `Explosives`. 가치 20. 거래 대가로 받는 NPC 는 없고 물자 지원(무기)만")
out.append("### 음식 (등급 = 열량)\n")
out.append("열량으로 등급 (1: 200 미만 … 5: 700 이상). 가치 = 열량/250 (0.5~4). 캔 음료처럼 갈증만 채우는 음식형 음료는 등급 풀 밖에서 "
           "가치 1로 받는다(B42의 병에 든 물·술은 음식이 아니라 액체 용기라 음식으로 받지 않는다). 통조림 상자 같은 묶음은 무게 x2.5\n")
for t in sorted(pool["food"]):
    out.append(f"**{t}등급 ({len(pool['food'][t])})**: " + ", ".join(nm(ft) for ft in pool["food"][t]) + "\n")
section("기호품 (물자 지원 전용)", groups["morale"],
        "읽을거리(`Literature`: 소설·잡지·만화·신문), 술(알코올이 든 것: 음식 `isAlcoholic` 또는 알코올 액체가 든 병·캔, "
        "다 마신 병은 제외), 담배(Cigarette·Cigar·Tobacco로 시작하는 `Junk`, 말린 담뱃잎), 배터리, 양초. "
        "기술서(`SkillBook`)·레시피 잡지·소품 책은 아니다. 거래 대가로는 안 받고 물자 지원에서 기호품을 채운다. "
        "가치 1 (담배 한 보루 8, 한 갑 2, 한 개비 0.2, 양초·말린 담뱃잎 0.5)")
section("차량 부품 (듀이 프로젝트 전용)", groups["vehicle"],
        "DisplayCategory `VehicleMaintenance`. 타이어·연료통 6, 브레이크·서스펜션·문·후드 5, 머플러·트렁크·앞유리 4, 창문·좌석 3, "
        "그 밖 4. 정비 도구(렌치·드라이버·라쳇·파이프렌치·토치·용접 마스크·용접봉·멀티툴)도 받는다")

stats = collections.Counter(v["src"] for v in items.values() if not v["obsolete"])
header = "<!-- generated from scripts: " + ", ".join(f"{k} {n}" for k, n in stats.items()) + " -->\n"
DOC = pathlib.Path(__file__).resolve().parents[1] / "docs" / "ITEM_CATEGORIES.md"
target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DOC
body = header + "\n".join(out)
if target.exists():
    old = target.read_text(encoding="utf-8")
    cut = old.find("<!-- generated")
    if cut < 0:
        cut = old.find("## 분류별 목록")
    if cut >= 0:
        body = old[:cut] + body
target.write_text(body, encoding="utf-8", newline="\n")
print(stats, {k: len(v) for k, v in groups.items()}, len(tool_in_melee), "tools in melee pool;",
      len(alcohol_fluids), "alcohol fluids")
