"""OVPrivacyCatalog must describe every network feature and every file that may touch the network.

Source-level checks (no build): the catalog is read as text, like tests/test_network_allowlist.py reads the sources.
"""
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
sys.path.insert(0, str(ROOT / "tests"))
import test_network_allowlist as allowlist  # noqa: E402

# Files that other tasks add (7.1, 7.6, 6.20, 8.7, 8.8); rows are ready for them. Remove a name when its file lands.
PENDING = {"OVBridge.m", "OVBridge.h"}

CATALOG = (SOURCES / "OVPrivacyCatalog.m").read_text()


def net_identifiers():
    body = (SOURCES / "OVNetwork.m").read_text()
    m = re.search(r"\+ \(NSString \*\)identifierFor:.*?\n\}\n", body, re.S)
    assert m, "identifierFor: not found in OVNetwork.m"
    return set(re.findall(r'return @"([a-z_]+)";', m.group(0)))


def method_body(name):
    m = re.search(r"\+ \(NSArray<NSDictionary \*> \*\)%s \{(.*?)\n\}\n" % name, CATALOG, re.S)
    assert m, "%s not found in OVPrivacyCatalog.m" % name
    return m.group(1)


def entries(name, helper):
    """The argument lists of every helper(...) call in the method, split at top-level commas."""
    body = method_body(name)
    out = []
    for m in re.finditer(r"\b%s\(" % helper, body):
        depth, i, start, args, in_str = 0, m.end(), m.end(), [], False
        while True:
            c = body[i]
            if in_str:
                if c == "\\":
                    i += 1
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c in "([":
                depth += 1
            elif c in ")]":
                if depth == 0:
                    args.append(body[start:i].strip())
                    break
                depth -= 1
            elif c == "," and depth == 0:
                args.append(body[start:i].strip())
                start = i + 1
            i += 1
        out.append(args)
    return out


class PrivacyCatalog(unittest.TestCase):
    def test_catalog_covers_every_net_feature(self):
        ids = net_identifiers()
        self.assertTrue(ids, "no identifiers found in OVNetwork.m")
        catalog_ids = {re.match(r'@"([a-z_]+)"', a[0]).group(1) for a in entries("networkEntries", "Net")}
        self.assertEqual(ids - catalog_ids, set(), "OVNetwork features without an OVPrivacyCatalog entry")
        self.assertEqual(catalog_ids - ids, set(), "OVPrivacyCatalog entries for features OVNetwork does not know")

    def test_every_network_entry_names_destination_and_data(self):
        rows = entries("networkEntries", "Net")
        self.assertTrue(rows)
        for a in rows:
            self.assertEqual(len(a), 6, a[0])
            for field in a[1:5]:   # title, destination, sends, when
                m = re.fullmatch(r'L\(@"([^"]+)"\)', field)
                self.assertTrue(m and m.group(1).strip(), "%s: field must be L(@\"…\") and not empty: %s" % (a[0], field))
            self.assertIn(a[5], ("YES", "NO"), a[0])

    def test_locations_ids_unique(self):
        rows = entries("locations", "Loc")
        ids = [re.match(r'@"([a-z_]+)"', a[0]).group(1) for a in rows]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(set(ids), {"voices", "outputs", "history", "logs", "models", "engines", "rvc", "plugins", "api", "bridge"})
        by_id = dict(zip(ids, rows))
        self.assertEqual(by_id["models"][3], "NO", "the shared Hugging Face cache is never deleted from this page")

    def test_catalog_mentions_every_allowlisted_network_file(self):
        known = {a[0].strip('@"'): ("model_download" if a[1] == "dl" else a[1].strip('@"')) for a in entries("networkSources", "Src")}  # dl = the model_download id variable
        feature_ids = {re.match(r'@"([a-z_]+)"', a[0]).group(1) for a in entries("networkEntries", "Net")}
        missing = sorted(set(allowlist.EXPECTED) - set(known))
        self.assertFalse(missing, "files in test_network_allowlist.EXPECTED without a row in OVPrivacyCatalog networkSources: %s" % missing)
        for f in allowlist.FORWARD:
            self.assertIn(f, known, "forward file %s is not described" % f)
        for f, feature in known.items():
            self.assertTrue(feature == "internal" or feature in feature_ids, "%s: unknown feature %s" % (f, feature))

    def test_every_source_row_names_an_existing_file_or_a_pending_one(self):
        existing = {p.name for p in SOURCES.rglob("*")}
        for a in entries("networkSources", "Src"):
            name = a[0].strip('@"')
            self.assertTrue(name in existing or name in PENDING,
                            "%s does not exist and is not in PENDING (a stale or misspelled row?)" % name)
        for name in PENDING:   # a pending file that has landed must leave the set
            self.assertNotIn(name, existing, "%s now exists: remove it from PENDING" % name)

    def test_no_network_markers_in_header_and_page(self):
        for name in ("OVPrivacyCatalog.h", "OVPrivacyPage.m"):
            for line in (SOURCES / name).read_text().splitlines():
                self.assertFalse(allowlist.MARKERS.search(line), "%s mentions a network marker: %s" % (name, line))


if __name__ == "__main__":
    unittest.main()
