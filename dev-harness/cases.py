import os, shutil, sys, random

NOW = int(sys.argv[1])
BASE = os.path.abspath("cases")
shutil.rmtree(BASE, ignore_errors=True)

def marker(rst, samp, pct_milli, slot=0):
    return "b_%012d_%012d_%03d.%03d_%04d" % (rst, samp, pct_milli//1000, pct_milli%1000, slot)

def mk(name, markers=(), tsv=(), extras=()):
    d = os.path.join(BASE, name)
    os.makedirs(os.path.join(d, "burn.d"))
    for m in markers:
        open(os.path.join(d, "burn.d", m), "w").close()
    for kind, fn in extras:
        p = os.path.join(d, "burn.d", fn)
        if kind == "dir":      os.makedirs(p)
        elif kind == "link":   os.symlink("/dev/null", p)
        elif kind == "fat":    open(p, "w").write("x")
    if tsv:
        with open(os.path.join(d, "burn.tsv"), "w") as f:
            for r in tsv: f.write(r + "\n")
    return d

R = NOW + 3600
# Legacy-bearing cases use a later reset that always beats the payload's
# (~NOW+3600 with second-level skew) yet stays inside the +21600 plausibility
# bound, so their rows deterministically own maxrst at runtime. TSV epochs are
# written unpadded: the decoder's strict epoch grammar rejects leading zeros.
RL = NOW + 10800
random.seed(7)

# 1 empty
mk("empty")
# 2 small, steadily rising
mk("small", [marker(R, NOW-10+i, 10000+i*700) for i in range(10)])
# 3 steady state at BURN_TRIM
mk("steady", [marker(R, NOW-1500+i, 10000+i*40) for i in range(1500)])
# 4 above BURN_TRIM -> trimming
mk("overtrim", [marker(R, NOW-1700+i, 10000+i*35) for i in range(1700)])
# 5 implausible mixed in (reset in the past, sample far in the future)
mk("implausible",
   [marker(R, NOW-200+i, 20000+i*300) for i in range(200)]
   + [marker(NOW-9999, NOW-50, 50000, 1), marker(R, NOW+99999, 50000, 2), marker(NOW+999999, NOW-5, 50000, 3)])
# 6 duplicate (reset,sample) groups, differing pct and slot
dups = []
for i in range(300):
    s = NOW-300+i
    dups.append(marker(R, s, 10000+i*90, 0))
    dups.append(marker(R, s, 10000+i*90+5, 1))   # higher pct wins
    dups.append(marker(R, s, 10000+i*90, 2))     # equal to slot 0, must not win
mk("dupgroups", dups)
# 7 junk entries: bad names, a dir, a symlink, a non-empty file
junk = [marker(R, NOW-100+i, 30000+i*400) for i in range(100)]
mk("junk", junk + ["b_bad", "notamarker", marker(R, NOW-5, 101000, 9)],
   extras=[("dir", "b_%012d_%012d_050.000_0007" % (R, NOW-3)),
           ("link", "b_%012d_%012d_050.000_0008" % (R, NOW-4)),
           ("fat",  "b_%012d_%012d_050.000_0009" % (R, NOW-6))])
# 8 legacy TSV only
mk("legacyonly", tsv=["%d\t%d\t%d" % (NOW-400+i, 20+i%40, RL) for i in range(400)])
# 9 legacy TSV + markers, same reset
mk("legacymix", [marker(RL, NOW-300+i, 30000+i*100) for i in range(300)],
   tsv=["%d\t%d\t%d" % (NOW-400+i, 20+i%40, RL) for i in range(400)])
# 10 legacy TSV with an older reset than the markers
mk("legacyold", [marker(RL, NOW-300+i, 30000+i*100) for i in range(300)],
   tsv=["%d\t%d\t%d" % (NOW-5000+i, 20+i%40, RL-4000) for i in range(400)])
# 11 flat series (no crossings) -> idle/warming path
mk("flat", [marker(R, NOW-600+i, 42000) for i in range(600)])
# 12 crossings outside the 600s window only
mk("oldcross", [marker(R, NOW-3000+i, 10000+i*80) for i in range(1200)])
# 13 migration backlog: steady-state markers plus capped same-reset legacy TSV,
#    every legacy sample older than every marker sample
mk("legacybacklog", [marker(RL, NOW-1500+i, 10000+i*40) for i in range(1500)],
   tsv=["%d\t%d\t%d" % (NOW-2100+i, 5+i%5, RL) for i in range(512)])

print(BASE)
