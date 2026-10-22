# Logs the context of each scroll frame over 300 ms (scrollperf), and prints it for the 5 MB page (perf.test).
s = open('test/scrollperf.mjs').read()
a = "        gaps.push(dt); last = now;\n"
assert s.count(a) == 1
s = s.replace(a, a + """        if (dt > 300) { const d = document.getElementById('ro-doc'); const hit = document.elementFromPoint(450, 450)?.closest('.chunk'); (window.__slow ||= []).push({ dt: Math.round(dt), mode, y: Math.round(se.scrollTop), h: se.scrollHeight, near: d.querySelectorAll(':scope > .chunk.near').length, stale: d.querySelectorAll(':scope > .chunk.stale').length, chunks: d.childElementCount, hit: hit ? [[...d.children].indexOf(hit), hit.childElementCount, Math.round(hit.getBoundingClientRect().height)] : null, trace: (window.readout.trace?.() || []).slice(-6).map(t => `${Math.round(t.t)}:${t.type}${t.delta != null ? ':' + t.delta : ''}`).join(' '), t: Math.round(now) }); }
""")
open('test/scrollperf.mjs', 'w').write(s)
p = open('test/perf.test.mjs').read()
a = "  const scroll5 = summary(await scrollPasses(p5));\n"
assert p.count(a) == 1
p = p.replace(a, a + "  console.log('SLOW', JSON.stringify(await p5.evaluate(() => window.__slow || [])));\n")
open('test/perf.test.mjs', 'w').write(p)
