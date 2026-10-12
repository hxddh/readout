"""Source of the Readout app icon: a dark display with one changed line.

Writes readout.svg (64 px and up) and readout-small.svg (16 and 32 px, fewer and
heavier lines). Render the PNGs with tools/icon/render.mjs.
"""
import os
import math
def squircle(cx=512, cy=512, r=412, n=5.0, steps=480):
    pts=[]
    for i in range(steps):
        t=2*math.pi*i/steps; c,s=math.cos(t),math.sin(t)
        pts.append(f"{cx+r*math.copysign(abs(c)**(2/n),c):.1f},{cy+r*math.copysign(abs(s)**(2/n),s):.1f}")
    return "M"+"L".join(pts)+"Z"
SQ = squircle()
def bar(x,y,w,h,fill,op=1):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{min(w,h)/2}" fill="{fill}" opacity="{op}"/>'
def wrap(defs, body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>{defs}
<clipPath id="sq"><path d="{SQ}"/></clipPath>
<filter id="drop" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>
</defs>
<path d="{SQ}" transform="translate(0 14)" fill="#000" opacity=".28" filter="url(#drop)"/>
{body}</svg>'''

# B: Readout (dark display, word-level change glows)
B = wrap('''<radialGradient id="b_bg" cx=".5" cy=".12" r="1"><stop offset="0" stop-color="#2B303D"/><stop offset=".6" stop-color="#15171E"/><stop offset="1" stop-color="#0C0D11"/></radialGradient>
<filter id="glow" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><feGaussianBlur stdDeviation="14"/></filter>
<linearGradient id="b_hi" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".25" stop-color="#fff" stop-opacity="0"/></linearGradient>''',
f'''<path d="{SQ}" fill="url(#b_bg)"/>
<g clip-path="url(#sq)">
{bar(272,292,300,58,"#F3EFE6")}
{bar(272,398,480,32,"#F3EFE6",.26)}
{bar(272,458,404,32,"#F3EFE6",.26)}
{bar(272,568,200,32,"#F3EFE6",.26)}{bar(486,568,266,32,"#F3EFE6",.26)}
{bar(272,628,170,32,"#F3EFE6",.26)}
<rect x="456" y="628" width="200" height="32" rx="16" fill="#4D8DFF" filter="url(#glow)" opacity=".9"/>
{bar(456,628,200,32,"#6FA4FF")}
<rect x="204" y="540" width="22" height="150" rx="11" fill="#4D8DFF" filter="url(#glow)" opacity=".8"/>
{bar(204,540,22,150,"#6FA4FF")}
{bar(272,730,300,32,"#F3EFE6",.26)}
</g>
<path d="{SQ}" fill="url(#b_hi)"/>
<path d="{SQ}" fill="none" stroke="#fff" stroke-opacity=".10" stroke-width="2"/>''')

# B small (16/32 px): fewer, heavier lines so the change still reads
Bs = wrap('''<radialGradient id="b_bg" cx=".5" cy=".12" r="1"><stop offset="0" stop-color="#2B303D"/><stop offset=".6" stop-color="#15171E"/><stop offset="1" stop-color="#0C0D11"/></radialGradient>
<linearGradient id="b_hi" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".25" stop-color="#fff" stop-opacity="0"/></linearGradient>''',
f'''<path d="{SQ}" fill="url(#b_bg)"/>
<g clip-path="url(#sq)">
{bar(272,300,320,84,"#F3EFE6")}
{bar(272,460,480,60,"#F3EFE6",.32)}
{bar(272,600,180,60,"#F3EFE6",.32)}{bar(472,600,240,60,"#6FA4FF")}
{bar(196,580,40,100,"#6FA4FF")}
</g>
<path d="{SQ}" fill="url(#b_hi)"/>''')


here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "readout.svg"), "w").write(B)
open(os.path.join(here, "readout-small.svg"), "w").write(Bs)
