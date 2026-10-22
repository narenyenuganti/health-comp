import subprocess
import sys
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / "verify-support-email.py"
ENCODED_HREF = "/cdn-cgi/l/email-protection#661f1408071403085726010b070f0a4805090b"
ENCODED_SPAN = '<span class="__cf_email__" data-cfemail="265f5448475443481766414b474f4a0845494b">[email&#160;protected]</span>'


class SupportEmailLinkTests(unittest.TestCase):
    def check_html(self, html: str, expected: bool) -> None:
        result = subprocess.run(
            [sys.executable, str(CHECKER)], input=html, text=True, capture_output=True
        )
        self.assertIn(result.returncode, (0, 1), result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_plain_mailto_link(self) -> None:
        self.check_html('<a href="mailto:yrnaren1@gmail.com">Contact support</a>', True)

    def test_cloudflare_encoded_link(self) -> None:
        self.check_html(f'<a class="contact" href="{ENCODED_HREF}">{ENCODED_SPAN}</a>', True)

    def test_wrong_plain_address(self) -> None:
        self.check_html('<a href="mailto:other@example.com">Contact support</a>', False)

    def test_wrong_encoded_href_even_with_correct_span(self) -> None:
        wrong_href = ENCODED_HREF[:-2] + "0a"
        self.check_html(f'<a href="{wrong_href}">{ENCODED_SPAN}</a>', False)

    def test_malformed_encoded_href(self) -> None:
        self.check_html(f'<a href="{ENCODED_HREF}z">{ENCODED_SPAN}</a>', False)

    def test_encoded_marker_without_link(self) -> None:
        self.check_html(ENCODED_SPAN, False)

    def test_mailto_text_outside_link(self) -> None:
        self.check_html('<script>"mailto:yrnaren1@gmail.com"</script>', False)

    def test_duplicate_href_does_not_hide_wrong_destination(self) -> None:
        self.check_html(
            '<a href="mailto:other@example.com" href="mailto:yrnaren1@gmail.com">Support</a>',
            False,
        )

    def test_empty_href_is_not_a_link(self) -> None:
        self.check_html("<a href>Support</a>", False)

    def test_expected_link_survives_unrelated_later_link(self) -> None:
        self.check_html(
            '<a href="mailto:yrnaren1@gmail.com">Support</a>'
            f'<a href="{ENCODED_HREF[:-2]}0a">Other</a>',
            True,
        )


if __name__ == "__main__":
    unittest.main()
