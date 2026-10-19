# dmgbuild settings for Readout's disk image (verify.yml builds it from the
# tested app). Run as:
#   dmgbuild -s settings.py -D app=PATH/Readout.app -D bg=PATH/background.png Readout OUT.dmg
# dmgbuild finds background@2x.png beside background.png and combines the two
# into one HiDPI TIFF. Coordinates are points in a 600 x 420 window, from its
# top-left corner, and match tools/dmg/background.swift.
# ruff: noqa: F821 - dmgbuild runs this file with `defines` set.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: dmgbuild sets it as Finder information on the bundle
# itself (com.apple.FinderInfo), which `codesign --verify --strict` rejects as
# detritus, and which a drag to Applications would copy. Finder hides ".app"
# by default anyway.

background = defines["bg"]
window_rect = ((200, 160), (600, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {app_name: (150, 180), "Applications": (450, 180)}
