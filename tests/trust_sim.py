"""신뢰도 유지 난이도 어림 계산 (후반, 싱글, 신뢰 하나). 게임의 실제 규칙을 줄여서 옮긴 모형이다.

규칙 묶음:
  now    지금 게임
  new    T1(믿은 만큼 아프게) + T2(높은 신뢰의 유지비) + T3(어려울 때 외면). 말 거는 것도 "상대함"으로 침
  strict new 와 같되 T2 의 "상대함"은 일(부탁·일거리·거래·지원을 끝냄)만 침
T6 은 초·중반 감점표라 후반 계산에는 영향이 없다 (아래 mid_table 에서 따로).
"""
import random
import statistics as st

NPCS = ["ray", "casey", "doc", "pike", "dewey", "guard", "rats", "hunter"]
START = {"ray": 30, "casey": 30, "doc": 25, "pike": 20, "dewey": 15, "guard": 10, "rats": 5, "hunter": 0}
KEY_BASE = {"ray": 45, "casey": 45, "doc": 55, "pike": 70, "dewey": 50, "guard": 75, "rats": 60, "hunter": 60}
LATE = {"declined": [1, 2, 3, 4, 5], "ignored": [2, 3, 4, 5, 6], "failed": [2, 4, 6, 8, 10]}
TIER_P = [(2, 0.40), (3, 0.30), (4, 0.20), (5, 0.10)]      # 후반 부탁 등급 (최소 2)

# 플레이어: 부탁에 대한 태도(완료/거절/무응답/실패), 주당 일거리·물자 지원·거래·특기 사용 횟수
PLAYERS = {
    "느긋함": dict(ask=(0.50, 0.25, 0.25, 0.00), vol=0, don=1, trade=1, spec=2, care=False),
    "보통":   dict(ask=(0.75, 0.15, 0.05, 0.05), vol=1, don=2, trade=2, spec=3, care=True),
    "성실":   dict(ask=(0.90, 0.05, 0.00, 0.05), vol=3, don=4, trade=3, spec=4, care=True),
    "올인":   dict(ask=(0.95, 0.03, 0.00, 0.02), vol=7, don=8, trade=4, spec=4, care=True),
}


def tier():
    r, acc = random.random(), 0
    for t, p in TIER_P:
        acc += p
        if r < acc:
            return t
    return 5


def band_tier(trust):
    return 1 + sum(trust >= b for b in (20, 40, 60, 80))


def t1(trust, rules):
    if rules == "now":
        return 1
    return 2 if trust >= 80 else (1.5 if trust >= 60 else 1)


def run(player, rules, days=60, start=85, seed=None):
    rnd = random.Random(seed)
    random.seed(seed)
    P = PLAYERS[player]
    trust = {n: start for n in NPCS}
    idle = {n: 0 for n in NPCS}           # 상대하지 않은 날 (규칙에 따라 말/일 기준)
    key = dict(KEY_BASE)
    low = {n: 0 for n in NPCS}            # 핵심 자원이 바닥인 채 돕지 않은 날
    neglect = {n: 0 for n in NPCS}        # 저절로 회복하지 않는 남은 날
    vol_week = {n: 0 for n in NPCS}
    trade_week = {n: 0 for n in NPCS}
    don_win = {n: 0 for n in NPCS}        # 물자 지원 3일 통 남은 날
    lost = {"T1": 0.0, "T2": 0.0, "T3": 0.0, "base": 0.0}
    gained = 0.0

    def add(n, d, why=None):
        nonlocal gained
        before = trust[n]
        if d > 0 and rules == "strict2":
            m = 0.5 if before >= 80 else (0.75 if before >= 60 else 1)
            whole = int(d * m)
            d = whole + (1 if rnd.random() < d * m - whole else 0)
        trust[n] = max(0, min(100, trust[n] + d))
        if d > 0:
            gained += trust[n] - before
        elif why:
            lost[why] += before - trust[n]

    def deed(n):
        idle[n] = 0
        low[n] = 0

    for day in range(1, days + 1):
        if day % 7 == 1:
            for n in NPCS:
                vol_week[n] = 0
                trade_week[n] = 0
        acts = {k: 0 for k in ("vol", "don", "trade", "spec")}
        for k in acts:                    # 주당 횟수를 날마다 고르게
            per = P[k] / 7.0
            acts[k] = int(per) + (1 if rnd.random() < per - int(per) else 0)
        # 말 거는 것: 누구나 사나흘에 한 번은 모두에게 말을 건다고 본다 (값이 안 드는 일)
        if rules not in ("strict", "strict2") and day % 3 == 0:
            for n in NPCS:
                idle[n] = 0
        # NPC 부탁: 이틀에 하나
        if day % 2 == 0:
            n = rnd.choice(NPCS)
            t = tier()
            r = rnd.random()
            pc, pd, pi, pf = P["ask"]
            if r < pc:
                add(n, t)
                deed(n)
                if rnd.random() < 0.5:
                    key[n] = min(100, key[n] + 10 * t)
            else:
                kind = "declined" if r < pc + pd else ("ignored" if r < pc + pd + pi else "failed")
                base = LATE[kind][t - 1]
                m = t1(trust[n], rules)
                add(n, -base, "base")
                if m > 1:
                    add(n, -(round(base * m) - base), "T1")
                key[n] = max(0, key[n] - 10)
                neglect[n] = 7
        # 일거리 청하기: 식어 가는 NPC 먼저 (없으면 신뢰가 가장 낮은 NPC)
        for _ in range(acts["vol"]):
            cand = [n for n in NPCS if vol_week[n] < 2]
            if not cand:
                break
            n = max(cand, key=lambda x: (idle[x] if trust[x] >= 60 else -1, -trust[x]))
            vol_week[n] += 1
            t = band_tier(trust[n])
            if rnd.random() < 0.9:
                add(n, t * 2)
                key[n] = min(100, key[n] + 10 * t)
                deed(n)
            else:
                m = t1(trust[n], rules)
                add(n, -t, "base")
                if m > 1:
                    add(n, -(round(t * m) - t), "T1")
        # 물자 지원 (작게, 가치 5~14: 신뢰 +1): 형편이 바닥인 NPC 먼저, 다음은 식어 가는 NPC
        for _ in range(acts["don"]):
            cand = [n for n in NPCS if don_win[n] == 0]
            if not cand:
                break
            n = max(cand, key=lambda x: ((key[x] < 20) if P["care"] else 0, idle[x], -trust[x]))
            don_win[n] = 3
            high = trust[n] >= 80
            add(n, 1)
            key[n] = min(100, key[n] + 15)
            if rules == "strict2" and high:
                low[n] = 0
            else:
                deed(n)
        # 거래: 주에 신뢰 +5 까지
        for _ in range(acts["trade"]):
            n = rnd.choice(NPCS)
            if trade_week[n] < 5:
                g = min(3, 5 - trade_week[n])
                trade_week[n] += g
                add(n, g)
            deed(n)
        # 특기 사용: 그 NPC 의 핵심 자원을 쓴다
        for _ in range(acts["spec"]):
            n = rnd.choice(NPCS)
            if key[n] >= 20 and trust[n] >= 40:
                key[n] -= 15
                if rules not in ("strict", "strict2"):
                    idle[n] = 0
        # 큰 사건: 17일쯤마다 두 곳의 형편이 크게 깎인다
        if day % 17 == 0:
            for n in rnd.sample(NPCS, 2):
                key[n] = max(0, key[n] - 25)
        # 하루 마감
        for n in NPCS:
            if don_win[n] > 0:
                don_win[n] -= 1
            # 형편: 20 이상이고 외면 기간이 아니면 기준값 쪽으로 5
            if neglect[n] > 0:
                neglect[n] -= 1
            elif key[n] >= 20:
                key[n] += max(-5, min(5, KEY_BASE[n] - key[n]))
            idle[n] += 1
            # 식음
            if rules == "now":
                if idle[n] >= 14 and (idle[n] - 14) % 3 == 0 and trust[n] > START[n] + 20:
                    add(n, -1, "base")
            else:
                if trust[n] >= 80:
                    if idle[n] > 4:
                        add(n, -1, "T2")
                elif trust[n] >= 60:
                    if idle[n] > 7 and (idle[n] - 7) % 2 == 0:
                        add(n, -1, "T2")
                elif idle[n] >= 14 and (idle[n] - 14) % 3 == 0 and trust[n] > START[n] + 20:
                    add(n, -1, "base")
                # T3: 핵심 자원이 바닥인데 사흘 넘게 돕지 않음
                if key[n] < 20:
                    low[n] += 1
                    if low[n] > 3:
                        add(n, -1, "T3")
                else:
                    low[n] = 0
    return trust, lost, gained


def table(start, days=60, trials=400):
    print(f"\n시작 신뢰도 {start}, {days}일 뒤 (NPC 8명, {trials}번 평균)")
    print(f"{'플레이어':8} {'규칙':7} {'평균':>6} {'80이상':>7} {'60이상':>7} {'얻음/월':>8} {'잃음/월':>8}   잃은 까닭 (월)")
    for p in PLAYERS:
        for rules in ("now", "new", "strict", "strict2"):
            means, hi, mid, gains, losses = [], [], [], [], {"T1": [], "T2": [], "T3": [], "base": []}
            for i in range(trials):
                trust, lost, gained = run(p, rules, days, start, seed=i)
                v = list(trust.values())
                means.append(st.mean(v))
                hi.append(sum(x >= 80 for x in v))
                mid.append(sum(x >= 60 for x in v))
                gains.append(gained * 30 / days)
                for k in losses:
                    losses[k].append(lost[k] * 30 / days)
            tot = sum(st.mean(losses[k]) for k in losses)
            why = "  ".join(f"{k} {st.mean(losses[k]):.0f}" for k in ("base", "T1", "T2", "T3"))
            print(f"{p:8} {rules:7} {st.mean(means):6.1f} {st.mean(hi):7.1f} {st.mean(mid):7.1f} "
                  f"{st.mean(gains):8.0f} {tot:8.0f}   {why}")


if __name__ == "__main__":
    table(85)
    table(50, days=90)
