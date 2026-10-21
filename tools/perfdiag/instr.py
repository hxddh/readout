# Temporary: adds phase timing to web/src/reader/patch.js apply() (diagnosis only).
import sys
p = sys.argv[1]
s = open(p).read()
def ins(before, tag):
    global s
    if s.count(before) != 1: print('skip', tag); return
    s = s.replace(before, f"__T('{tag}');\n  " + before)
s = s.replace("export function apply(p) {", "const __T = n => { (window.__ph ||= []).push([n, performance.now()]); };\nexport function apply(p) {\n  window.__ph = []; __T('start');")
ins("const anchor = isFirst ? null", "held")
ins("let changeNearViewport = false;", "anchor")
ins("const follow = following && !p.rewrite", "near")
ins("renderMarks(p.marks || []", "ops")
ins("for (const el of maybeVisible)", "marks")
ins("// Restore position in the same task", "visible")
ins("const own = anchor && slots.get", "restore")
ins("post({ type: 'applied'", "rest")
open(p, 'w').write(s)
