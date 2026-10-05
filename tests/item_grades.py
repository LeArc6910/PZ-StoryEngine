"""거래 등급 분류 (2026-10-04 사용자 결정 기준). 게임·모드 아이템 스크립트, 바닐라 루팅표, 레시피, 인게임 분류
결과(itempool.txt)로 품목별 등급·제외 이유·가치를 매긴다.

사용:
  python tests/item_grades.py                     shared/StoryEngine/ItemTiers.lua 를 다시 만든다
  python tests/item_grades.py --catalog out.json  거래 핵심 표 편집기(아티팩트)에 넣을 목록도 쓴다
다른 스크립트(gen_item_doc.py)는 import 해서 ITEMS 를 쓴다.

게임 쪽 규칙(ItemPool.lua, Value.lua)과 같게 맞춘다. 게임이 실행 중에 알 수 없는 값(도구 루팅 등급, 따기 전
통조림·상자 속 물건, 의약품 등급)만 ItemTiers.lua 로 넘기고, 나머지(음식 수치, 근접 무기 점수, 총 사격 방식,
탄약 구경)는 게임이 아이템에서 직접 읽는다. 경로는 개발 PC 기준."""
import json, os, re, sys, pathlib, collections

GAME = pathlib.Path(r"E:/SteamLibrary/steamapps/common/ProjectZomboid/media")
WS = pathlib.Path(r"E:/SteamLibrary/steamapps/workshop/content/108600")
ROOT = pathlib.Path(__file__).resolve().parents[1]
MOD = ROOT / "mod/StoryEngine/42/media"
POOL = pathlib.Path(os.path.expanduser("~")) / "Zomboid/Lua/StoryEngine/itempool.txt"
TIERS_LUA = MOD / "lua/shared/StoryEngine/ItemTiers.lua"
MOD_DIRS = (("VFE", WS / "3577903007/mods/Vanilla Foods Expanded"),
            ("MFS", WS / "3633421539/mods/Escape from Kentucky4215"),
            ("A-Life", WS / "3803984183/mods/ProjectALifeNPCs"))


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
for _label, _root in MOD_DIRS:
    if _root.exists():
        for _m in version_dirs(_root):
            MEDIA.append((_label, _m))

# ---------------------------------------------------------------- 아이템 스크립트 (모드가 같은 아이템을 다시 정의하면 합친다)
NUM = {"MinDamage": "minDmg", "MaxDamage": "maxDmg", "ConditionMax": "cond", "ConditionLowerChanceOneIn": "condChance",
       "BaseSpeed": "speed", "MaxHitcount": "hits", "Weight": "weight"}
scripts = {}
for label, media in MEDIA:
    for f in (media / "scripts").rglob("*.txt"):
        text = re.sub(r"/\*.*?\*/", "", f.read_text(encoding="utf-8", errors="replace"), flags=re.S)
        module, depth, cur, cur_depth, entered = None, 0, None, None, False
        for rawline in text.splitlines():
            line = rawline.split("//")[0].strip()
            if not line:
                continue
            m = re.match(r"module\s+(\w+)", line)
            if m and depth == 0:
                module = m.group(1)
            m = re.match(r"item\s+([\w\-]+)", line)
            if m and module and cur is None and depth == 1:
                cur = module + "." + m.group(1)
                scripts.setdefault(cur, {"src": label, "dc": "", "obsolete": False, "raw": {}})
                cur_depth, entered = depth, False
            if cur and depth == cur_depth + 1:
                info = scripts[cur]
                m = re.match(r"(\w+)\s*=\s*(.*?),?$", line)
                if m:
                    info["raw"][m.group(1).lower()] = m.group(2).strip()
                    if m.group(1) == "DisplayCategory":
                        info["dc"] = m.group(2).strip()
                    if m.group(1) in NUM:
                        try:
                            info[NUM[m.group(1)]] = float(m.group(2).strip())
                        except ValueError:
                            pass
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
            names[k.replace("ItemName_", "")] = v.strip()


def raw(ft):
    return scripts.get(ft, {}).get("raw", {})


def num(r, k):
    try:
        return float(r.get(k, "0") or 0)
    except ValueError:
        return 0.0


# ---------------------------------------------------------------- 인게임 분류 결과 (음식·근접 무기·총 풀, 예전 등급)
pool_tier = {}
if POOL.exists():
    cur = None
    for line in POOL.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\[(\w+) (\d)\] \d+", line)
        if m:
            cur = (m.group(1), int(m.group(2)))
            continue
        if cur and line.startswith("  "):
            body = line.strip()
            if cur[0] == "firearm":
                m = re.match(r"(\S+)\s+round=", body)
                if m:
                    pool_tier[("firearm", m.group(1))] = cur[1]
            else:
                for ft in (x.strip() for x in body.split(",")):
                    if ft:
                        pool_tier[(cur[0], ft)] = cur[1]

# ---------------------------------------------------------------- 따기·풀기 레시피: 통조림·상자 -> (안에 든 것, 개수)
recipe_out = {}
for root in [GAME / "scripts"] + [r for _, r in MOD_DIRS if r.exists()]:
    for f in root.rglob("*.txt"):
        t = f.read_text(encoding="utf-8", errors="replace")
        for blk in re.finditer(r"craftRecipe\s+\w+\s*\{(.*?)\n    \}", t, re.S):
            b = blk.group(1)
            mappers = {}
            for m in re.finditer(r"itemMapper\s+(\w+)\s*\{(.*?)\}", b, re.S):
                mappers[m.group(1)] = {inp: out for out, inp in re.findall(r"([\w\.]+)\s*=\s*([\w\.]+)", m.group(2))}
            ins = re.search(r"inputs\s*\{(.*?)\}", b, re.S)
            outs = re.search(r"outputs\s*\{(.*?)\}", b, re.S)
            if not ins or not outs:
                continue
            out_items = re.findall(r"item\s+(\d+)\s+(mapper:\w+|[\w\.]+)", outs.group(1))
            if len(out_items) != 1:
                continue
            n, out = int(out_items[0][0]), out_items[0][1]
            # 소모 재료가 한 줄·한 개인 레시피만 (따기·풀기). 여러 개를 담는 포장·여러 재료 요리는 뺀다
            used = [ln for ln in ins.group(1).splitlines() if re.search(r"item\s+\d+", ln)
                    and "mode:keep" not in ln and "tags[" not in ln]
            if len(used) != 1 or not re.search(r"item\s+1\s", used[0]):
                continue
            m = re.search(r"item\s+\d+\s+\[([^\]]+)\]", used[0])
            lst = m.group(1).split(";") if m else re.findall(r"item\s+\d+\s+([\w]+\.[\w]+)", used[0])
            for inp in lst:
                inp = inp.strip()
                o = mappers.get(out[7:], {}).get(inp) if out.startswith("mapper:") else out
                if o and "." in o and inp not in recipe_out:
                    recipe_out[inp] = (o, n)

# ---------------------------------------------------------------- 도구: 바닐라 루팅표 등장 가중치 합
L = GAME / "lua"
loot_w, loot_n = collections.Counter(), collections.Counter()
for f in set((L / "server/Items").glob("*Distribution*.lua")) | set(L.rglob("VehicleDistributions.lua")):
    t = f.read_text(encoding="utf-8", errors="replace")
    t = re.sub(r"--\[\[.*?\]\]", "", t, flags=re.S)
    t = re.sub(r"--[^\n]*", "", t)
    for m in re.finditer(r'"([A-Za-z0-9_\.]+)"\s*,\s*([\d\.]+)', t):
        nm = m.group(1) if "." in m.group(1) else "Base." + m.group(1)
        loot_w[nm] += float(m.group(2))
        loot_n[nm] += 1

# ---------------------------------------------------------------- 규칙 (ItemPool.lua 와 같게)
FOOD_CUTS = [(40, 5), (25, 4), (15, 3), (10, 2), (0, 1)]
MED = {
    1: ["Bandaid", "AdhesiveBandageBox", "Bandage", "AlcoholBandage", "BandageBox", "AlcoholWipes", "CottonBalls",
        "AlcoholedCottonBalls", "CottonBallsBox", "Disinfectant", "Coldpack", "ColdpackBox", "ScissorsBluntMedical"],
    2: ["Pills", "PillsBeta", "PillsAntiDep", "PillsSleepingTablets", "PillsVitamins", "Antibiotics", "AntibioticsBox"],
    3: ["Tweezers", "Tweezers_Forged", "SutureNeedle", "SutureNeedleBox", "SutureNeedleHolder", "Forceps_Forged",
        "Scalpel", "Splint"],
}
MED_TIER = {"Base." + n: t for t, ns in MED.items() for n in ns}
MED_NO_USE = {"Base.Tissue", "Base.TissueBox", "Base.Stethoscope", "Base.TongueDepressor", "Base.TongueDepressorBox"}
NOT_MEDICAL = {"Base.BandageDirty", "Base.Gloves_Surgical", "Base.Hat_SurgicalCap", "Base.Hat_SurgicalMask",
               "Base.MortarPestle", "Base.CeramicMortarandPestle"}
TOOL_NOT = ["Debug", "Mold", "Unfired", "Parts", "SeedPaste", "Tobacco"]
CRAFTED = re.compile(r"Forged|Stone|Bone|Crude|Carved|Flint|Improvised|_Wood$|Crafted|_Scrap|Knapping")
OLD = re.compile(r"_Old$|Old$|^Old")
MELEE_WEIGHTS = {"life": 1, "speed": 0.5, "hits": 0.5}      # ItemPool.MELEE_WEIGHTS
MELEE_MATERIAL_OK = {"Base.Plank", "Base.MetalPipe", "Base.LeadPipe", "Base.MetalBar", "Base.Firewood"}
CAL = {  # 구경 id: (등급, 이름, 대략 총구 에너지 J)
    "bolt": (1, "석궁 화살", 100), "38": (1, ".38 스페셜", 300), "9mm": (1, "9x19mm", 500), "45": (1, ".45 ACP", 500),
    "357": (2, ".357 매그넘", 800), "44": (2, ".44 매그넘", 1500),
    "545": (3, "5.45x39mm", 1300), "556": (3, "5.56x45mm", 1750), "58": (3, "5.8x42mm", 1900),
    "3030": (4, ".30-30", 2500), "12g": (4, "12게이지", 3000), "308": (4, "7.62x51mm (.308)", 3500),
    "86": (5, ".338 라푸아 (8.6mm)", 6500), "50": (5, ".50 BMG", 18000), "145": (5, "14.5mm", 30000),
}
AMMOTYPE = {"bullets_38": "38", "bullets_9mm": "9mm", "bullets_45": "45", "bullets_357": "357", "bullets_44": "44",
            "bullets_3030": "3030", "bullets_308": "308", "bullets_556": "556", "shotgun_shells": "12g",
            "cat_545bullets": "545", "cat_58bullets": "58", "cat_bullets86": "86", "cat_bullets50": "50",
            "cat_bullets145": "145", "cat_crossbowbolt": "bolt"}
NAME_CAL = [
    (r"^(fire|boom)bolt|Grenade|RPG", None), (r"Crossbow|^bolt$", "bolt"), (r"145", "145"),
    (r"^Bullets50|^50", "50"), (r"Bullets86|^86|^338", "86"), (r"^545", "545"), (r"^A_58|^58|^95Drum", "58"),
    (r"^556|M91|AR57|JS14|PAL", "556"), (r"^3030", "3030"), (r"^308|^762|^M14|MG42|M240|MK47", "308"),
    (r"Shotgun|AA12|Typhoon", "12g"), (r"357", "357"), (r"44", "44"), (r"^Bullets45|^45", "45"),
    (r"9mm", "9mm"), (r"38|^68", "38"),
]
ACTION_MOD = {"auto": 2, "manual": -2, "semi": 0, "pump": 0}
ACTION_TEXT = {"auto": "+2 (자동)", "manual": "-2 (수동 장전)", "semi": "(반자동·리볼버)", "pump": "(펌프, 그대로)"}
# 기본 탄창 용량 (ItemPool.CAPACITY_MOD 와 같음): 21발 이상 +1, 36발 이상 +2, 60발 이상 +3
CAPACITY_MOD = [(60, 3), (36, 2), (21, 1)]


def capacity_mod(rounds):
    for at, mod in CAPACITY_MOD:
        if rounds >= at:
            return mod
    return 0


def gun_rounds(r):
    mag = (r.get("magazinetype") or "").strip()
    if mag:
        ft = mag if "." in mag else "Base." + mag
        n = num(raw(ft), "maxammo")
        if n > 0:
            return int(n)
    return int(num(r, "maxammo"))
VALUE = {"food": [0.5, 1, 1.5, 2.5, 4], "medical": [2, 4, 6], "tools": [2, 4, 8, 14, 20],
         "melee": [3, 4, 5, 8, 12], "firearm": [30, 40, 50, 65, 80],
         "ammo_box": [10, 13, 15, 20, 30], "ammo_mag": [3, 4, 5, 6, 8]}
KINDS = {
    "tools": ["tool", "tools", "toolweapon", "toolkit", "hardware"],
    "medical": ["firstaid", "firstaidweapon", "bandage", "medical", "medicine", "medic", "medkit", "pharmacy"],
    "ammo": ["ammo", "ammunition"],
    "vehicle": ["vehiclemaintenance", "vehiclemaintenanceweapon", "vehicle", "vehicleparts", "carparts"],
    "electronics": ["electronics", "communications", "lightsource", "electronic"],
}
KIND_OF = {n: k for k, ns in KINDS.items() for n in ns}
SPECIAL_OTHER = {"Base.Generator": 60, "Base.CarBattery1": 15, "Base.CarBattery2": 15, "Base.EngineParts": 3,
                 "Base.HamRadio1": 40, "Base.HamRadio2": 40}


def cal_of_ammotype(a):
    return AMMOTYPE.get((a or "").lower().split(":")[-1])


def cal_of_ammo_item(ft):
    r = raw(ft)
    if r.get("ammotype"):
        c = cal_of_ammotype(r["ammotype"])
        if c or "grenade" in r["ammotype"].lower():
            return c, True
    short = ft.split(".", 1)[1]
    for pat, c in NAME_CAL:
        if re.search(pat, short):
            return c, True
    return None, False


def gun_action(r):
    modes = (r.get("firemodepossibilities", "") + " " + r.get("firemode", "")).lower()
    reload = r.get("weaponreloadtype", "").lower()
    rack = r.get("rackaftershoot", "").lower() == "true"
    if "auto" in modes:
        return "auto"
    if reload == "shotgun":
        return "pump"
    if rack or reload in ("boltactionnomag", "leveraction", "doublebarrelshotgun", "doublebarrelshotgunsawn"):
        return "manual"
    return "semi"


def food_relief(ft, depth=0):
    r = raw(ft)
    h, th = max(0.0, -num(r, "hungerchange")), max(0.0, -num(r, "thirstchange"))
    if h > 0 or th > 0 or depth >= 2 or ft not in recipe_out:
        return h, th, None
    o, n = recipe_out[ft]
    h2, th2, _ = food_relief(o, depth + 1)
    return h2 * n, th2 * n, "%s x%d" % (o, n)


# ---------------------------------------------------------------- 분류
def entry(ft, cat):
    s = scripts.get(ft, {})
    return {"ft": ft, "n": names.get(ft, "") or ft.split(".", 1)[1], "cat": cat, "src": s.get("src", "?"), "v": 0.2}


ITEMS = []
by_ft = {}


def add(e):
    if e["ft"] not in by_ft:
        by_ft[e["ft"]] = e
        ITEMS.append(e)


for (pcat, ft), t in sorted(pool_tier.items()):
    dc = scripts.get(ft, {}).get("dc", "").lower()
    if dc in ("tool", "toolweapon") and not any(w in ft for w in TOOL_NOT):
        continue      # 무기 겸 도구는 거래에서 도구
    if pcat in ("food", "melee", "firearm"):
        e = entry(ft, pcat)
        e["t"] = t
        add(e)
for ft, info in sorted(scripts.items()):
    if info["obsolete"] or ft in by_ft:
        continue
    kind = KIND_OF.get(info["dc"].lower())
    short = ft.split(".", 1)[1]
    if kind == "tools" and not any(w in short for w in TOOL_NOT):
        add(entry(ft, "tools"))
    elif kind == "medical" and ft not in NOT_MEDICAL and "RippedSheets" not in ft and "Dirty" not in ft:
        add(entry(ft, "medical"))
    elif kind in ("ammo", "vehicle", "electronics"):
        e = entry(ft, kind)
        e["v"] = SPECIAL_OTHER.get(ft, 0.2)
        add(e)

melee_ok = []
for e in ITEMS:
    ft, c, r = e["ft"], e["cat"], raw(e["ft"])
    s = scripts.get(ft, {})
    short = ft.split(".", 1)[1]
    if c == "food":
        h, th, via = food_relief(ft)
        e["h"], e["th"] = round(h, 1), round(th, 1)
        if via:
            e["via"] = via
        total = h + th
        e["nt"] = next(t for cut, t in FOOD_CUTS if total >= cut)
        e["why"] = "배고픔 %g + 갈증 %g = %g" % (e["h"], e["th"], round(total, 1)) + (" (%s)" % via if via else "")
    elif c == "medical":
        if ft in MED_TIER:
            e["nt"] = MED_TIER[ft]
        elif ft in MED_NO_USE:
            e["ex"] = "치료 효과 없음"
        else:
            e["ex"] = "채집 약초 (채집물 규칙으로 거래 안 받음)"
    elif c == "tools":
        e["loot"], e["lists"] = round(loot_w[ft], 2), loot_n[ft]
        if CRAFTED.search(short):
            e["ex"] = "손으로 만드는 원시·대장간 도구"
        elif OLD.search(short):
            e["ex"] = "낡은 변형 (같은 도구의 녹슨 판)"
        elif loot_w[ft] == 0:
            e["ex"] = "바닐라 루팅표에 없음"
    elif c == "melee":
        mn, mx = s.get("minDmg", 0), s.get("maxDmg", 0)
        cond, chance = s.get("cond", 0), s.get("condChance", 0)
        wcat = r.get("categories", "").replace("base:", "")
        e.update({"minDmg": mn, "maxDmg": mx, "cond": cond, "condChance": chance, "speed": s.get("speed", 1),
                  "hits": s.get("hits", 1), "twoHand": r.get("twohandweapon", "").lower() == "true", "wcat": wcat,
                  "life": round(cond * max(1, chance))})
        if short == "BareHands" or "unarmed" in wcat:
            e["ex"] = "맨손"
        elif "Broken" in short:
            e["ex"] = "부서진 무기"
        elif s.get("dc", "").lower() == "materialweapon" and ft not in MELEE_MATERIAL_OK:
            e["ex"] = "무기 부품 (재료)"
        else:
            w = MELEE_WEIGHTS
            e["mscore"] = round((mn + mx) / 2 * (e["speed"] or 1) ** w["speed"] * max(1, e["life"]) ** w["life"]
                                * (e["hits"] or 1) ** w["hits"], 2)
            melee_ok.append(e)
    elif c == "ammo":
        cal, known = cal_of_ammo_item(ft)
        if not cal:
            e["ex"] = "폭발물·특수탄" if known else "구경 모름"
        else:
            e["cal"], e["nt"] = cal, CAL[cal][0]
            e["why"] = "%s (약 %s J)" % (CAL[cal][1], format(CAL[cal][2], ","))
            if cal in ("50", "145"):
                e["ex"] = "대물 저격탄 (거래·보상에서 빠진 탄, 쓰는 총도 제외)"
    elif c == "firearm":
        cal = cal_of_ammotype(r.get("ammotype"))
        act = gun_action(r)
        e["act"] = act
        if not cal:
            e["ex"] = "탄약 모름"
        else:
            base = CAL[cal][0]
            rounds = gun_rounds(r)
            cap = capacity_mod(rounds)
            e["cal"], e["nt"] = cal, max(1, min(5, base + ACTION_MOD[act] + cap))
            e["why"] = "%s %d등급 %s" % (CAL[cal][1], base, ACTION_TEXT[act])
            if cap:
                e["why"] += " +%d (탄창 %d발)" % (cap, rounds)

# 근접 무기: 실전 점수 5분위
melee_ok.sort(key=lambda e: e["mscore"])
for i, e in enumerate(melee_ok):
    e["nt"] = min(5, i * 5 // len(melee_ok) + 1)
    e["why"] = "실전 점수 %g" % e["mscore"]

# 도구: 루팅 가중치가 낮을수록 높은 등급 (남은 도구의 5분위)
tools_ok = sorted([e for e in ITEMS if e["cat"] == "tools" and "ex" not in e], key=lambda e: -e["loot"])
for i, e in enumerate(tools_ok):
    e["nt"] = min(5, i * 5 // len(tools_ok) + 1)
    e["why"] = "루팅 가중치 합 %g (목록 %d곳)" % (e["loot"], e["lists"])
TOOL_CUTS = {}
for e in tools_ok:
    lo, hi = TOOL_CUTS.get(e["nt"], (1e9, 0))
    TOOL_CUTS[e["nt"]] = (min(lo, e["loot"]), max(hi, e["loot"]))

# 전자기기(케이시)·차량 부품(듀이): 도구처럼 루팅표에서 드문 정도. 루팅표에 없는 것(차에서 떼는 부품, 켜진 상태,
# 직접 만드는 것)은 팔지 않는다. 대가로는 받지 않고(거래 분류 아님) 가치는 도구와 같은 표
LOOT_TIERED = {}
for cat in ("electronics", "vehicle"):
    es = [e for e in ITEMS if e["cat"] == cat]
    for e in es:
        e["loot"], e["lists"] = round(loot_w[e["ft"]], 2), loot_n[e["ft"]]
        short = e["ft"].split(".", 1)[1]
        if loot_w[e["ft"]] == 0:
            e["ex"] = "바닐라 루팅표에 없음 (차에서 떼는 부품·켜진 상태·직접 만드는 것)"
        elif CRAFTED.search(short):
            e["ex"] = "손으로 만드는 것"
        elif re.match(r"LightBulb.+", short):
            e["ex"] = "장식용 색 전구"
    ok = sorted([e for e in es if not e.get("ex")], key=lambda e: -e["loot"])
    for i, e in enumerate(ok):
        e["nt"] = min(5, i * 5 // len(ok) + 1)
        e["why"] = "루팅 가중치 합 %g (목록 %d곳)" % (e["loot"], e["lists"])
        e["v"] = VALUE["tools"][e["nt"] - 1]
    LOOT_TIERED[cat] = ok

# 가치 (등급을 따른다. 상자는 안에 든 것 x 개수)
for e in ITEMS:
    t = e.get("nt")
    if not t or e.get("ex"):
        continue
    if e["cat"] in ("food", "medical", "tools", "melee", "firearm"):
        e["v"] = VALUE[e["cat"]][t - 1]
    elif e["cat"] == "ammo":
        short = e["ft"].split(".", 1)[1].lower()
        if "carton" in short:
            e["v"] = VALUE["ammo_box"][t - 1] * 12
        elif "box" in short:
            e["v"] = VALUE["ammo_box"][t - 1]
        elif "clip" in short or "mag" in short or "drum" in short or "belt" in short:
            e["v"] = VALUE["ammo_mag"][t - 1]
        else:
            per_box = next((n for box, (o, n) in recipe_out.items() if o == e["ft"] and "Box" in box), 20)
            e["v"] = round(VALUE["ammo_box"][t - 1] / per_box, 2)
def in_contents(e):
    """ItemTiers.CONTENTS 에 들어가는가 (게임 Value 가 상자 가치를 안에 든 것 x 개수로 계산하는 대상)"""
    if e["ft"] not in recipe_out:
        return False
    n = recipe_out[e["ft"]][1]
    short = e["ft"].split(".", 1)[1]
    return (e["cat"] == "food" and bool(e.get("via"))) or \
        (e["cat"] in ("medical", "ammo") and n >= 2 and re.search(r"Box|Carton|Pack", short) is not None)


for e in ITEMS:
    inside = recipe_out.get(e["ft"])
    if e["cat"] in ("medical", "food") and not e.get("ex") and in_contents(e) and inside[1] >= 2 and inside[0] in by_ft:
        e["v"] = round(by_ft[inside[0]]["v"] * inside[1], 2)

RULES = {"food": {"cuts": FOOD_CUTS}, "tools": {"cuts": {str(k): v for k, v in sorted(TOOL_CUTS.items())}},
         "ammo": {"cal": {k: list(v) for k, v in CAL.items()}}, "melee": MELEE_WEIGHTS}


# ---------------------------------------------------------------- ItemTiers.lua (ASCII)
def lua_str(x):
    assert all(ord(ch) < 128 for ch in x), x
    return '"' + x + '"'


def write_lua(path=TIERS_LUA):
    lines = ["-- Generated by tests/item_grades.py (trade grade rules of 2026-10-04). Do not edit by hand.",
             "-- Data the game cannot work out by itself at runtime:",
             "--   TOOLS: tool tier from vanilla loot tables (sum of spawn weights, rarer = higher tier)",
             "--   TOOL_EXCLUDED: vanilla tools that are not traded (hand-made, worn variants, not in loot)",
             "--   CONTENTS: sealed food / box / carton -> { item inside, count } (from the opening and unpacking recipes)",
             "--   MEDICAL: medical tier (1 dressing/cleaning, 2 taken by mouth, 3 serious wound care)",
             "--   ELECTRONICS, VEHICLE: tier from vanilla loot tables like tools (Casey and Dewey sell these)",
             "--   *_BOUNDS: loot-weight cut-offs of those tiers, so the game can tier items from other mods at runtime",
             "--             (weight >= BOUNDS[1] -> tier 1, >= BOUNDS[2] -> 2, ... below BOUNDS[4] -> 5)",
             "local ItemTiers = {}", "StoryEngine = StoryEngine or {}", "StoryEngine.ItemTiers = ItemTiers", ""]
    lines.append("ItemTiers.TOOLS = {")
    for e in sorted(tools_ok, key=lambda e: e["ft"]):
        lines.append("    [%s] = %d," % (lua_str(e["ft"]), e["nt"]))
    lines.append("}")
    lines.append("ItemTiers.TOOL_EXCLUDED = {")
    for e in sorted([e for e in ITEMS if e["cat"] == "tools" and e.get("ex")], key=lambda e: e["ft"]):
        lines.append("    [%s] = true," % lua_str(e["ft"]))
    lines.append("}")
    lines.append("ItemTiers.CONTENTS = {")
    for e in sorted(ITEMS, key=lambda e: e["ft"]):
        if in_contents(e):
            o, n = recipe_out[e["ft"]]
            lines.append("    [%s] = { %s, %d }," % (lua_str(e["ft"]), lua_str(o), n))
    lines.append("}")
    lines.append("ItemTiers.MEDICAL = {")
    for ft, t in sorted(MED_TIER.items()):
        lines.append("    [%s] = %d," % (lua_str(ft), t))
    lines.append("}")
    lines.append("ItemTiers.MEDICAL_NO_USE = {")
    for ft in sorted(MED_NO_USE):
        lines.append("    [%s] = true," % lua_str(ft))
    lines.append("}")
    for cat, name in (("electronics", "ELECTRONICS"), ("vehicle", "VEHICLE")):
        lines.append("ItemTiers.%s = {" % name)
        for e in sorted(LOOT_TIERED[cat], key=lambda e: e["ft"]):
            lines.append("    [%s] = %d," % (lua_str(e["ft"]), e["nt"]))
        lines.append("}")
    def bounds(entries):
        cut = {}
        for e in entries:
            lo = cut.get(e["nt"])
            cut[e["nt"]] = e["loot"] if lo is None else min(lo, e["loot"])
        return [cut.get(t, 0) for t in (1, 2, 3, 4)]
    for name, entries in (("TOOL_BOUNDS", tools_ok), ("ELECTRONICS_BOUNDS", LOOT_TIERED["electronics"]),
                          ("VEHICLE_BOUNDS", LOOT_TIERED["vehicle"])):
        lines.append("ItemTiers.%s = { %s }" % (name, ", ".join(repr(round(b, 4)) for b in bounds(entries))))
    lines += ["", "return ItemTiers"]
    path.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\r\n")


if __name__ == "__main__":
    write_lua()
    if "--catalog" in sys.argv:
        out = pathlib.Path(sys.argv[sys.argv.index("--catalog") + 1])
        out.write_text(json.dumps({"items": ITEMS, "rules": RULES}, ensure_ascii=False), encoding="utf-8")
    for c in ("food", "medical", "tools", "melee", "ammo", "firearm", "electronics", "vehicle"):
        es = [e for e in ITEMS if e["cat"] == c]
        cnt = collections.Counter(e.get("nt") for e in es if "ex" not in e)
        exc = collections.Counter(e["ex"] for e in es if "ex" in e)
        print(c, len(es), dict(sorted(cnt.items())), "excluded", sum(exc.values()))
