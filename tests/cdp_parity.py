# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.65.2"]
# ///
"""With lightpanda serve running, use: uv run tests/cdp_parity.py
Set CDP_ENDPOINT to run against another browser, e.g. headless Chromium.
"""

import os
import sys
import unittest

from playwright.sync_api import Error, sync_playwright


class CDPParity(unittest.TestCase):
    def setUp(self):
        playwright = sync_playwright().start()
        self.addCleanup(playwright.stop)
        browser = playwright.chromium.connect_over_cdp(
            os.environ.get("CDP_ENDPOINT", "http://127.0.0.1:9222")
        )
        self.page = browser.new_page()
        self.addCleanup(self.page.context.close)
        self.cdp = self.page.context.new_cdp_session(self.page)

    def test_only_links_in_layout_have_a_box(self):
        self.page.set_content("""
            <a id="in-layout" href="/" style="visibility:hidden">First link</a>
            <a id="out-of-layout" href="/" style="display:none">Second link</a>
        """)
        root = self.cdp.send("DOM.getDocument")["root"]

        def box_for(selector):
            node = self.cdp.send(
                "DOM.querySelector",
                {
                    "nodeId": root["nodeId"],
                    "selector": selector,
                },
            )
            self.assertNotEqual(node["nodeId"], 0, selector)
            return self.cdp.send("DOM.getBoxModel", {"nodeId": node["nodeId"]})["model"]

        box = box_for("#in-layout")
        self.assertGreater(box["width"], 0)
        self.assertGreater(box["height"], 0)
        try:
            hidden = box_for("#out-of-layout")
        except Error as error:
            self.assertIn("Could not compute box model", str(error))
        else:
            if os.environ.get("CDP_LIGHTPANDA_BASELINE") == "1":
                self.assertEqual((hidden["width"], hidden["height"]), (0, 0))
                print(
                    "Known difference: display:none returned a zero-size box",
                    file=sys.stderr,
                )
            else:
                self.fail("display:none returned a box")

    def test_accessibility_tree_tracks_live_selection(self):
        self.page.set_content("""
            <select aria-label="Order">
              <option value="date" selected>By date</option>
              <option value="name">By name</option>
            </select>
        """)

        def selection():
            nodes = self.cdp.send("Accessibility.getFullAXTree")["nodes"]
            controls = [n for n in nodes if n["role"]["value"] == "combobox"]
            self.assertEqual(len(controls), 1)
            selected = [
                n["name"]["value"]
                for n in nodes
                if n["role"]["value"] == "option"
                and not n["ignored"]
                and any(
                    p["name"] == "selected" and p["value"]["value"] is True
                    for p in n.get("properties", [])
                )
            ]
            return controls[0].get("value", {}).get("value"), selected

        before = selection()
        # The selected attribute stays on the first option after this change.
        self.page.locator("select").select_option("name")
        after = selection()
        for (value, selected), label, html_value in (
            (before, "By date", "date"),
            (after, "By name", "name"),
        ):
            with self.subTest(label):
                self.assertEqual(selected, [label])
                if (
                    os.environ.get("CDP_LIGHTPANDA_BASELINE") == "1"
                    and value == html_value
                ):
                    print(
                        f"Known difference: combobox value is {value!r} for {label!r}",
                        file=sys.stderr,
                    )
                else:
                    self.assertEqual(value, label)


if __name__ == "__main__":
    unittest.main()
