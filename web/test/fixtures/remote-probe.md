# Remote resource probe

This document must not trigger any network request at render time.
Each construct below renders as a click-to-load placeholder instead.

![plain markdown remote image](https://track.example/a.png)

<img src="https://track.example/b.png" alt="raw html img">

<div style="background-image:url(https://track.example/c.png)">styled div</div>

<video poster="https://track.example/d.png"></video>

<svg width="10" height="10"><image href="https://track.example/e.png"/></svg>

<input type="image" src="https://track.example/f.png" alt="input image">

<table background="https://track.example/g.png"><tr><td>cell</td></tr></table>

<img srcset="local.png 1x, https://track.example/h.png 2x" src="local.png" alt="srcset">
