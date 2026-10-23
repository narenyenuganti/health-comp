#!/usr/bin/env python3
"""Check that the support page links to the expected email address."""

import re
import sys
from html.parser import HTMLParser


ADDRESS = "yrnaren1@gmail.com"
ENCODED_LINK = "/cdn-cgi/l/email-protection#"


class SupportLink(HTMLParser):
    found = False

    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        hrefs = [value for name, value in attrs if name == "href"]
        if len(hrefs) != 1:
            return
        href = hrefs[0] or ""
        if href == f"mailto:{ADDRESS}":
            self.found = True
            return
        if not href.startswith(ENCODED_LINK):
            return
        token = href[len(ENCODED_LINK) :]
        if not re.fullmatch(r"(?:[0-9a-fA-F]{2}){2,}", token):
            return
        payload = bytes.fromhex(token)
        try:
            decoded = bytes(byte ^ payload[0] for byte in payload[1:]).decode("utf-8")
        except UnicodeDecodeError:
            return
        if decoded == ADDRESS:
            self.found = True


parser = SupportLink()
parser.feed(sys.stdin.read())
sys.exit(0 if parser.found else 1)
