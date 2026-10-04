"""게임·모드 아이템 스크립트와 인게임 분류 결과(itempool.txt)로 docs/ITEM_CATEGORIES.md 의 목록 부분을 다시 만든다.
사용: python tests/gen_item_doc.py   (문서에서 목록 앞부분은 그대로 두고 뒤를 바꾼다)
경로(게임·창작마당·모드 목록)는 개발 PC 기준. 모드 구성이 바뀌면 MEDIA 목록과, 인게임 디버그 "아이템 분류"로 만든 itempool.txt 를 갱신한다.
등급·제외·가치는 item_grades.py (게임 ItemPool.lua·Value.lua 와 같은 규칙, 2026-10-04 새 기준)에서 가져온다."""
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import item_grades as G     # noqa: E402  등급·제외·가치 (2026-10-04 새 기준)

MORALE_SPECIAL = {"Base.Battery", "Base.Candle", "Base.CigaretteCarton", "Base.CigarettePack", "Base.CigaretteSingle",
                  "Base.CigaretteRolled", "Base.TobaccoDried"}

# 분류 이름 -> 종류 (게임 ItemPool.CATEGORY_KINDS 와 같게)
CATEGORY_KINDS = {
    "explosive": ["explosives", "explosive", "bomb", "bombs", "grenade", "grenades"],
    "literature": ["literature", "book", "books", "magazine", "magazines", "reading"],
    "vehicle": ["vehiclemaintenance", "vehiclemaintenanceweapon", "vehicle", "vehicleparts", "carparts", "carpart",
                "autoparts"],
}
KIND_OF = {n: k for k, names in CATEGORY_KINDS.items() for n in names}


def kind(dc):
    return KIND_OF.get((dc or "").lower())


graded = {e["ft"] for e in G.ITEMS}
groups = collections.defaultdict(list)
for ft, info in sorted(items.items()):
    if info["obsolete"]:
        continue
    dc = info["cat"] or ""
    short = ft.split(".", 1)[1]
    if ft not in graded and (info["ranged"] or (dc in ("Weapon", "FireArm") and info["ammo"])):
        groups["gun_other"].append(ft)
    elif kind(dc) == "explosive":
        groups["explosive"].append(ft)
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


def fmt(v):
    return ("%g" % v)


def graded_section(cat, title, note, show_why=False):
    es = [e for e in G.ITEMS if e["cat"] == cat]
    ok = [e for e in es if not e.get("ex")]
    out.append(f"### {title} ({len(ok)})\n")
    out.append(note + "\n")
    for t in range(1, 6):
        lst = sorted([e for e in ok if e.get("nt") == t], key=lambda e: e["ft"])
        if not lst:
            continue
        out.append(f"**{t}등급 ({len(lst)})**: " + ", ".join(
            nm(e["ft"]) + (f" ({e['why']})" if show_why and e.get("why") else "") for e in lst) + "\n")
    ex = collections.defaultdict(list)
    for e in es:
        if e.get("ex"):
            ex[e["ex"]].append(e["ft"])
    for why, lst in sorted(ex.items()):
        out.append(f"**거래 제외 — {why} ({len(lst)})**: " + ", ".join(nm(ft) for ft in sorted(lst)) + "\n")


out.append("## 분류별 목록\n")
graded_section("firearm", "총기 (등급 = 탄약 + 사격 방식)",
               "가치 30/40/50/65/80. 탄약 등급에서 자동 사격 가능 +2, 수동 장전(볼트·레버·더블 배럴) -2, "
               "펌프 산탄총·반자동·리볼버는 그대로 (1~5로 자름)", show_why=True)
if groups["gun_other"]:
    section("총기 (등급 풀 밖)", groups["gun_other"],
            "원거리 무기지만 등급 풀에서 빠진 것: .50 BMG·14.5mm·유탄·화염 연료를 쓰거나, 탄약이 탄약 분류가 아니거나, "
            "장난감 총. 대가로는 총기 3등급 가치(50)로 받지만 보상·거래 상품으로는 나오지 않는다")
cal = sorted(G.CAL.values(), key=lambda c: c[2])
graded_section("ammo", "탄약 (등급 = 구경 위력)",
               "구경: " + " / ".join(f"{t} " + "·".join(c[1] for c in cal if c[0] == t) for t in range(1, 6))
               + ". 가치: 상자 10/13/15/20/30, 탄창 3/4/5/6/8, 낱발 = 상자 / 상자 속 발 수, 카톤 = 상자 x 12")
graded_section("melee", "근접 무기 (등급 = 실전 점수)",
               "실전 점수 = 평균 피해 x 속도^0.5 x 수명 x 타격 수^0.5 (수명 = 최대 내구도 x 내구 감소 확률 분모)의 5분위. "
               "가치 3/4/5/8/12. 무기 겸 도구(`ToolWeapon`: 망치·렌치·도끼 등)는 보상으로는 근접 무기로 나오지만 "
               "거래·물자 지원에서는 도구라서 아래 도구 목록에 있다", show_why=True)
cuts = G.TOOL_CUTS
graded_section("tools", "도구 (등급 = 바닐라 루팅표에서 나오는 정도)",
               "DisplayCategory `Tool`·`ToolWeapon`. 루팅표 가중치 합이 작을수록(드물수록) 높은 등급, 5분위: "
               + " / ".join(f"{t}등급 {fmt(cuts[t][0])}~{fmt(cuts[t][1])}" for t in sorted(cuts))
               + ". 가치 2/4/8/14/20. 표에 없는 모드 도구는 3등급", show_why=True)
graded_section("medical", "의약품",
               "1 상처를 덮고 닦는 것 / 2 먹으면 효과가 있는 것 / 3 큰 상처 처치. 가치 2/4/6, 상자는 안에 든 것 x 개수. "
               "표에 없는 모드 의약품은 1등급")
graded_section("electronics", "전자기기 (케이시가 파는 것, 등급 = 바닐라 루팅표에서 나오는 정도)",
               "도구와 같은 방식(루팅표 가중치 합 5분위), 가치 2/4/8/14/20. 거래 대가로는 받지 않는다(배터리·양초는 물자 지원 기호품). "
               "루팅표에 없는 것·직접 만드는 것·장식용 색 전구는 팔지 않는다", show_why=True)
graded_section("vehicle", "차량 부품 등급 (듀이가 파는 것)",
               "도구와 같은 방식, 가치 2/4/8/14/20. 듀이 묶음에는 정비 도구(렌치·드라이버·라쳇·파이프렌치·토치·용접 마스크·용접봉·멀티툴)도 "
               "도구 등급으로 섞인다. 차에서 떼어 내는 부품(문·후드·좌석 등)은 루팅표에 없어 팔지 않는다", show_why=True)
section("폭발물", groups["explosive"], "DisplayCategory `Explosives`. 군용 수류탄 20, 그 밖 3. "
        "거래 대가로 받는 NPC 는 없고 물자 지원(무기)만")
graded_section("food", "음식 (등급 = 배고픔 + 갈증 해소)",
               "1: 10 미만 / 2: 10~14 / 3: 15~24 / 4: 25~39 / 5: 40 이상 (짠 음식의 갈증은 0, 따기 전 통조림·상자는 안에 든 "
               "음식 x 개수). 가치 0.5/1/1.5/2.5/4. 캔 음료처럼 갈증만 채우는 음식형 음료는 등급 풀 밖에서 가치 0.5로 받는다", show_why=True)
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
print(stats, {k: len(v) for k, v in groups.items()}, len(alcohol_fluids), "alcohol fluids")
