#!/usr/bin/env python3
"""Writes a Sparkle appcast.xml for one release, signed with the EdDSA (Ed25519) update key.

usage: appcast.py ZIP VERSION BUILD DOWNLOAD_URL NOTES_URL MIN_SYSTEM OUT
The private key is read from the SPARKLE_PRIVATE_KEY environment variable (base64 32-byte seed).
"""
import base64
import email.utils
import os
import sys
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def main():
    zip_path, version, build, url, notes, min_system, out = sys.argv[1:8]
    seed = base64.b64decode(os.environ["SPARKLE_PRIVATE_KEY"].strip())
    key = Ed25519PrivateKey.from_private_bytes(seed[:32])
    data = open(zip_path, "rb").read()
    signature = base64.b64encode(key.sign(data)).decode()
    date = email.utils.formatdate(usegmt=True)
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Readout</title>
    <link>https://github.com/hxddh/readout</link>
    <description>Readout updates</description>
    <language>en</language>
    <item>
      <title>Version {escape(version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(notes)}</sparkle:releaseNotesLink>
      <enclosure url="{escape(url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
    with open(out, "w") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
