"""밖에서 온 사람들의 신뢰도 관리 난이도 어림 계산 (docs/IDEAS_COUNCIL_ERA.md 12-2).

trust_sim.py 의 모형(지금 게임의 신뢰 규칙: T1·T2·T3·T7)에 밖에서 온 무리를 얹었다. 깔아 둔 가정:
  - 밖에서 온 사람은 생활 자원·프로젝트가 없다 -> T3 없음. 신뢰를 올리는 길은 부탁·일거리·(오델) 거래와
    "선물" (물자 지원처럼 사흘 통에 신뢰만 오름, 2026-10-13 확정)
  - 부탁은 서버 전체로 이틀에 하나, 와 있는 모든 NPC 가운데 무작위
  - 처음 신뢰 35. 특기는 1차 신뢰 40, 2차 신뢰 70. 쓸 때마다 꺼리는 원래 NPC 셋의 신뢰 -2 (R1, 2026-10-13 확정)
  - "힘든 쪽" (E10~E13 에서 원래 NPC 를 고른 뒤): 일을 해 주지 않은 날이 이틀 쌓일 때마다 -1, 얻는 양 절반,
    30 미만이 3일 이어지면 떠남
  - 플레이어는 일거리를 "목표(70)에서 가장 먼 사람, 식기 직전인 사람, 떠날 위험이 있는 사람"에게 먼저 쓴다
    (밖에서 온 사람도 일거리 청하기를 받는다고 본다. 아직 정하지 않은 것)
실제 수치는 게임에서 다시 맞춰야 한다. 방향과 크기를 보는 용도다.
"""
import random
import statistics as st

ORIG = ["ray", "casey", "doc", "pike", "dewey", "guard", "rats", "hunter"]
KEY_BASE = {"ray": 45, "casey": 45, "doc": 55, "pike": 70, "dewey": 50, "guard": 75, "rats": 60, "hunter": 60}
OUT = {
    "hale": dict(dislike=["guard", "rats", "hunter"], cd=(14, 7)),
    "odell": dict(dislike=["rats", "ray", "dewey"], cd=(7, 7)),
    "okafor": dict(dislike=["doc", "pike", "hunter"], cd=(7, 14)),
    "abigail": dict(dislike=["pike", "doc", "casey"], cd=(14, 7)),
}
LATE = {"declined": [1, 2, 3, 4, 5], "ignored": [2, 3, 4, 5, 6], "failed": [2, 4, 6, 8, 10]}
TIER_P = [(2, 0.40), (3, 0.30), (4, 0.20), (5, 0.10)]
PLAYERS = {
    "느긋함": dict(ask=(0.50, 0.25, 0.25, 0.00), vol=0, don=1, trade=1),
    "보통":   dict(ask=(0.75, 0.15, 0.05, 0.05), vol=1, don=2, trade=2),
    "성실":   dict(ask=(0.90, 0.05, 0.00, 0.05), vol=3, don=4, trade=3),
    "올인":   dict(ask=(0.95, 0.03, 0.00, 0.02), vol=7, don=8, trade=4),
}
R1 = 2
OUT_START = 35
HARD_EVERY = 2                    # 힘든 쪽: 일 없는 날이 이만큼 쌓일 때마다 -1
TARGET = 70
LEAVE_BELOW, LEAVE_DAYS = 30, 3


def band_tier(trust):
    return 1 + sum(trust >= b for b in (20, 40, 60, 80))


def pain(trust):
    return 2 if trust >= 80 else (1.5 if trust >= 60 else 1)


def run(player, outsiders, days=60, orig_start=70, out_start=OUT_START, use=1.0, hard=(), seed=None, r1=R1,
        every=HARD_EVERY, gifts=True):
    """use = 열린 특기를 쓰는 비율 (1.0 = 대기가 풀릴 때마다). hard = 힘든 쪽이 된 무리 이름들."""
    rnd = random.Random(seed)
    P = PLAYERS[player]
    npcs = ORIG + list(outsiders)
    trust = {n: orig_start for n in ORIG}
    trust.update({n: out_start for n in outsiders})
    idle = {n: 0 for n in npcs}
    key = dict(KEY_BASE)
    low = {n: 0 for n in ORIG}
    neglect = {n: 0 for n in ORIG}
    vol_week = {n: 0 for n in npcs}
    trade_week = {n: 0 for n in npcs}
    don_win = {n: 0 for n in npcs}
    ready = {n: [0, 0] for n in outsiders}        # 특기 대기가 풀리는 날
    below = {n: 0 for n in outsiders}
    left = {}                                      # 떠난 날
    reach = {n: [None, None] for n in outsiders}   # 40, 70 에 처음 닿은 날
    uses = 0

    def tier():
        r, acc = rnd.random(), 0
        for t, p in TIER_P:
            acc += p
            if r < acc:
                return t
        return 5

    def add(n, d, raw=False):
        if n in left:
            return
        before = trust[n]
        if d > 0 and not raw:
            m = 0.5 if before >= 80 else (0.75 if before >= 60 else 1)
            if n in hard:
                m *= 0.5
            whole = int(d * m)
            d = max(1, whole + (1 if rnd.random() < d * m - whole else 0))
        trust[n] = max(0, min(100, trust[n] + d))

    def deed(n):
        idle[n] = 0
        if n in low:
            low[n] = 0

    def here():
        return [n for n in npcs if n not in left]

    def want(x):
        score = max(0, TARGET - trust[x])
        if x in hard:
            score += 20 if trust[x] < 60 else 5
        elif (trust[x] >= 80 and idle[x] >= 4) or (trust[x] >= 60 and idle[x] >= 7):
            score += 15
        return (score, idle[x])

    for day in range(1, days + 1):
        if day % 7 == 1:
            for n in npcs:
                vol_week[n] = 0
                trade_week[n] = 0
        acts = {}
        for k in ("vol", "don", "trade"):
            per = P[k] / 7.0
            acts[k] = int(per) + (1 if rnd.random() < per - int(per) else 0)
        # 부탁: 이틀에 하나, 와 있는 모든 NPC 가운데
        if day % 2 == 0:
            n = rnd.choice(here())
            t = tier()
            r = rnd.random()
            pc, pd, pi, pf = P["ask"]
            if r < pc:
                add(n, t)
                deed(n)
                if n in key and rnd.random() < 0.5:
                    key[n] = min(100, key[n] + 10 * t)
            else:
                kind = "declined" if r < pc + pd else ("ignored" if r < pc + pd + pi else "failed")
                add(n, -round(LATE[kind][t - 1] * pain(trust[n])), raw=True)
                if n in key:
                    key[n] = max(0, key[n] - 10)
                    neglect[n] = 7
        # 일거리 청하기: 떠날 위험이 있는 사람 > 식어 가는 사람 > 신뢰가 낮은 사람
        for _ in range(acts["vol"]):
            cand = [n for n in here() if vol_week[n] < 2 and trust[n] >= 20]
            if not cand:
                break
            n = max(cand, key=want)
            vol_week[n] += 1
            t = band_tier(trust[n])
            if rnd.random() < 0.9:
                add(n, t * 2)
                deed(n)
                if n in key:
                    key[n] = min(100, key[n] + 10 * t)
            else:
                add(n, -round(t * pain(trust[n])), raw=True)
        # 물자 지원 (밖에서 온 사람에게는 "선물": 신뢰만)
        for _ in range(acts["don"]):
            cand = [n for n in here() if don_win[n] == 0 and (n in ORIG or gifts)]
            if not cand:
                break
            n = max(cand, key=lambda x: (key.get(x, 100) < 20, want(x)))
            don_win[n] = 3
            high = trust[n] >= 80
            add(n, 1)
            if n in key:
                key[n] = min(100, key[n] + 15)
            if high:
                low[n] = 0
            else:
                deed(n)
        # 거래: 원래 NPC 와 오델
        for _ in range(acts["trade"]):
            n = rnd.choice([x for x in here() if x in ORIG or x == "odell"])
            if trade_week[n] < 5:
                g = min(3, 5 - trade_week[n])
                trade_week[n] += g
                add(n, g)
            deed(n)
        # 밖에서 온 사람의 특기: 열려 있고 대기가 풀렸으면 쓴다 -> 꺼리는 원래 NPC 신뢰 -4
        for n in outsiders:
            if n in left:
                continue
            for i, need in enumerate((40, 70)):
                if trust[n] >= need and day >= ready[n][i] and rnd.random() < use:
                    ready[n][i] = day + OUT[n]["cd"][i]
                    uses += 1
                    for d in OUT[n]["dislike"]:
                        add(d, -r1, raw=True)
        # 큰 사건: 17일쯤마다 두 곳의 형편이 깎인다
        if day % 17 == 0:
            for n in rnd.sample(ORIG, 2):
                key[n] = max(0, key[n] - 25)
        # 하루 마감
        for n in here():
            idle[n] += 1
            if don_win[n] > 0:
                don_win[n] -= 1
            if n in ORIG:
                if neglect[n] > 0:
                    neglect[n] -= 1
                elif key[n] >= 20:
                    key[n] += max(-5, min(5, KEY_BASE[n] - key[n]))
            if n in hard:
                if idle[n] >= 1 and idle[n] % every == 0:      # 일 없는 날이 every 일 쌓일 때마다
                    add(n, -1, raw=True)
            elif trust[n] >= 80:
                if idle[n] > 4:
                    add(n, -1, raw=True)
            elif trust[n] >= 60:
                if idle[n] > 7 and (idle[n] - 7) % 2 == 0:
                    add(n, -1, raw=True)
            if n in ORIG:
                if key[n] < 20:
                    low[n] += 1
                    if low[n] > 3:
                        add(n, -1, raw=True)
                else:
                    low[n] = 0
            else:
                for i, need in enumerate((40, 70)):
                    if reach[n][i] is None and trust[n] >= need:
                        reach[n][i] = day
                below[n] = below[n] + 1 if trust[n] < LEAVE_BELOW else 0
                if n in hard and below[n] >= LEAVE_DAYS:
                    left[n] = day
    return trust, reach, left, uses


def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else float("nan")


def climb(trials=300):
    print(f"\n[1] 신뢰 {OUT_START} 에서 시작해 특기가 열리기까지 (120일 안, 그동안 열린 특기는 절반쯤 씀)")
    print(f"{'플레이어':8} {'무리 수':>6} {'40 닿는 날':>10} {'70 닿는 날':>10} {'120일 안에 70':>13}")
    for p in PLAYERS:
        for outs in (["okafor"], list(OUT)):
            d40, d70, got = [], [], []
            for i in range(trials):
                _, reach, _, _ = run(p, outs, days=120, use=0.5, seed=i)
                for n in outs:
                    d40.append(reach[n][0])
                    d70.append(reach[n][1])
                    got.append(reach[n][1] is not None)
            print(f"{p:8} {len(outs):>6} {mean(d40):>10.0f} {mean(d70):>10.0f} {100 * st.mean(got):>12.0f}%")


def cost(trials=300):
    print("\n[2] 특기를 쓸 때 원래 NPC 들이 치르는 값 (밖에서 온 사람 75, 원래 NPC 70 에서 시작, 60일 뒤)")
    print(f"{'플레이어':8} {'무리 수':>6} {'값':>3} {'쓰는 비율':>8} {'한 달 횟수':>9} {'꺼리는 NPC 평균':>14} {'40 미만':>7} {'30 미만':>7}")
    for p in ("보통", "성실", "올인"):
        for outs in (["hale"], list(OUT)):
            hated = sorted({d for n in outs for d in OUT[n]["dislike"]})
            for r1, use in ((2, 0.5), (2, 1.0), (4, 1.0)):
                a, lo40, lo30, us = [], [], [], []
                for i in range(trials):
                    trust, _, _, uses = run(p, outs, days=60, out_start=75, use=use, seed=i, r1=r1)
                    a.append(st.mean(trust[n] for n in hated))
                    lo40.append(sum(trust[n] < 40 for n in ORIG))
                    lo30.append(sum(trust[n] < 30 for n in ORIG))
                    us.append(uses / 2)
                print(f"{p:8} {len(outs):>6} {-r1:>3} {use:>8.0%} {st.mean(us):>9.0f} {st.mean(a):>14.0f} "
                      f"{st.mean(lo40):>7.1f} {st.mean(lo30):>7.1f}")


def leave(trials=300):
    print("\n[3] 힘든 쪽이 된 뒤 (원래 NPC 를 고름): 60일 안에 떠나는 비율과 떠나는 날")
    print(f"{'플레이어':8} {'힘든 무리':>8} {'그때 신뢰':>8} {'떠남':>6} {'떠나는 날':>9} {'남은 사람의 60일 뒤 신뢰':>22}")
    for p in PLAYERS:
        for hard in (["okafor"], list(OUT)):
            for s in (70, 45):
                gone, when, end = [], [], []
                for i in range(trials):
                    trust, _, left, _ = run(p, list(OUT), days=60, out_start=s, use=0.25, hard=hard, seed=i)
                    for n in hard:
                        gone.append(n in left)
                        when.append(left.get(n))
                        if n not in left:
                            end.append(trust[n])
                print(f"{p:8} {len(hard):>8} {s:>8} {100 * st.mean(gone):>5.0f}% {mean(when):>9.0f} {mean(end):>22.0f}")


if __name__ == "__main__":
    climb()
    cost()
    leave()
