# Logs what each 5 MB scroll frame over 50 ms held: the page's own long callbacks (with a sketch of
# the function), and what changed in the document in it (scrollperf; printed by perf.test).
s = open('test/scrollperf.mjs').read()
a = "        try { return f.apply(this, a); } finally { if (window.__ownOn) log.push(performance.now() - t); }"
assert s.count(a) == 1
s = s.replace(a, "        try { return f.apply(this, a); } finally { const d = performance.now() - t; if (window.__ownOn) { log.push(d); if (d > 20) (window.__longOwn ||= []).push({ t: Math.round(t), d: Math.round(d), f: String(f).replace(/\\s+/g, ' ').slice(0, 90) }); } }")
a = "        gaps.push(dt); last = now;\n"
assert s.count(a) == 1
s = s.replace(a, """        if (!window.__mo2) { window.__mo2 = true; window.__muts = {}; new MutationObserver(Object.assign(rs => { for (const r of rs) { const b = (r.target.closest ? r.target : r.target.parentElement)?.closest?.('.blk'); const k = (b ? (b.className.match(/k-(\\w+)/) || [])[1] : r.target.nodeName) + ':' + r.type + ':' + (r.attributeName || '') + (r.attributeName === 'data-hl' ? '=' + r.target.getAttribute('data-hl') : r.attributeName === 'class' && r.target.classList.contains('mermaid-block') ? '=' + r.target.className : ''); window.__muts[k] = (window.__muts[k] || 0) + 1; } }, { __h: true })).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['data-hl', 'class'] }); }
        if (dt > 50 && window.__ownOn) { const own = (window.__longOwn || []).filter(o => o.t >= last - 5); (window.__slow ||= []).push({ dt: Math.round(dt), mode, y: Math.round(se.scrollTop), muts: window.__muts, own, near: document.querySelectorAll('#ro-doc > .chunk.near').length }); }
        window.__muts = {};
""" + a)
open('test/scrollperf.mjs', 'w').write(s)
p = open('test/perf.test.mjs').read()
a = "  const scroll5 = summary(await scrollPasses(p5));\n"
assert p.count(a) == 1
p = p.replace(a, a + "  console.log('SLOW', JSON.stringify(scroll5), JSON.stringify(await p5.evaluate(() => window.__slow || [])));\n")
open('test/perf.test.mjs', 'w').write(p)
