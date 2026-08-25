#!/usr/bin/env python3
"""Static contracts for the formal localized Settings surface."""

from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "networkmanagerprefs"
ROOT_PLIST = PREFS / "Resources/Root.plist"
ENGLISH = PREFS / "Resources/en.lproj/NetworkManagerPrefs.strings"
CHINESE = PREFS / "Resources/zh-Hans.lproj/NetworkManagerPrefs.strings"
CELLS = PREFS / "CCNMPreferencesCells.m"
CONTROLLER = PREFS / "CCNMRootListController.m"
CONTROL = ROOT / "control"

# Every UPPER_SNAKE literal in the bundle's own sources, plus every such value in
# Root.plist. This is deliberately wider than the localized-string call sites: a
# key can reach the table through a lookup dictionary (recoveryStateLocalizationKey)
# or through a plist row, and matching only CCNMPreferencesLocalizedString call
# sites reports those as unused.
KEY_LITERAL = re.compile(r'@"([A-Z][A-Z0-9_]{3,})"')
BARE_KEY = re.compile(r"[A-Z0-9_]+")

ORIGINAL_REPO = "https://github.com/NoisyFlake/NetworkManager"
MAINTAINED_REPO = "https://github.com/doimty/NetworkManagerReborn"


def control_version() -> str:
    """The shipped version, from the file dpkg reads.

    Read rather than hardcoded so the About row cannot silently disagree with the
    package it is inside. That mismatch is invisible on the device -- the row just
    shows a number, and nothing cross-checks it.
    """
    for line in CONTROL.read_text(encoding="utf-8").splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"no Version field in {CONTROL}")


def strings_table(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    pairs = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', text, re.MULTILINE)
    table = {}
    for key, value in pairs:
        if key in table:
            raise AssertionError(f"duplicate localization key {key} in {path}")
        table[key] = value
    nonempty = [line for line in text.splitlines() if line.strip() and not line.lstrip().startswith("//")]
    if len(pairs) != len(nonempty):
        raise AssertionError(f"unparsed localization line in {path}")
    return table


def referenced_localization_keys() -> set[str]:
    keys = set()
    for source in sorted(PREFS.glob("*.m")) + sorted(PREFS.glob("*.h")):
        keys |= set(KEY_LITERAL.findall(source.read_text(encoding="utf-8")))

    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
        elif isinstance(node, str) and BARE_KEY.fullmatch(node):
            keys.add(node)

    walk(plistlib.loads(ROOT_PLIST.read_bytes()))
    return keys


class FormalSettingsUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plist = plistlib.loads(ROOT_PLIST.read_bytes())
        cls.items = cls.plist["items"]
        cls.english = strings_table(ENGLISH)
        cls.chinese = strings_table(CHINESE)
        cls.cells = CELLS.read_text()
        cls.controller = CONTROLLER.read_text()

    def test_localization_key_parity_and_required_chinese(self):
        self.assertEqual(set(self.english), set(self.chinese))
        for key in (
            "HEADER_SUBTITLE",
            "GROUP_N78_PREFERENCE",
            "TOGGLE_N78_PREFERENCE",
            "GROUP_CURRENT_STATE",
            "GROUP_RECOVERY",
            "ORIGINAL_PROJECT",
            "MAINTAINED_SOURCE",
        ):
            self.assertIn(key, self.chinese)
            self.assertTrue(self.chinese[key].strip())
        self.assertEqual(self.chinese["TOGGLE_N78_PREFERENCE"], "启用 n78 偏好")

    def test_pull_over_inspired_header_is_compact_and_independent(self):
        headers = [item for item in self.items if item.get("cellClass") == "CCNMHeaderCell"]
        self.assertEqual(len(headers), 1)
        self.assertIs(self.items[0], headers[0])
        self.assertEqual(headers[0].get("height"), 88.0)
        self.assertEqual(headers[0].get("label"), "HEADER_TITLE")
        self.assertEqual(headers[0].get("subtitle"), "HEADER_SUBTITLE")
        for token in (
            "constraintEqualToConstant:46.0",
            "preferredFontForTextStyle",
            "secondaryLabelColor",
            "adjustsFontForContentSizeCategory",
        ):
            self.assertIn(token, self.cells)

    def test_repository_links_are_exact_and_present_once(self):
        urls = [item.get("url") for item in self.items if item.get("url")]
        self.assertEqual(urls.count(ORIGINAL_REPO), 1)
        self.assertEqual(urls.count(MAINTAINED_REPO), 1)
        self.assertEqual(len(urls), 2)
        for item in self.items:
            if item.get("url"):
                self.assertEqual(item.get("cellClass"), "CCNMRepositoryLinkCell")
                self.assertEqual(item.get("action"), "openRepository:")
        self.assertIn('@selector(systemImageNamed:)', self.cells)

    def test_requested_applied_serving_and_recovery_are_separate_rows(self):
        identifiers = [item.get("id") for item in self.items]
        for identifier in (
            "n78Preference",
            "transitionState",
            "requestedPolicy",
            "appliedPolicy",
            "servingState",
            "dataLine",
            "freshness",
            "recoveryState",
            # The recovery action used to be "restore original bands", replaying the
            # saved baseline into the modem. It is a carrier defaults reload now:
            # the same button, a mechanism that needs no saved record to undo an
            # enable, so it also works when the baseline is missing or foreign.
            "resetCarrierDefaults",
        ):
            self.assertEqual(identifiers.count(identifier), 1)
        self.assertNotIn("restoreOriginalBands", identifiers)
        self.assertIn("rebuildRecoverySection", self.controller)
        self.assertIn("removeObjectsInArray:self.recoverySpecifiers", self.controller)
        loader_start = self.controller.index("loadSpecifiersFromPlistName:")
        loader_end = self.controller.index("[self localizeSpecifiers:loaded]", loader_start)
        self.assertIn(
            "mutableCopy",
            self.controller[loader_start:loader_end],
            "the Preferences loader may return an immutable NSArray; make the working list mutable before removal",
        )

    def test_ios15_uses_pslistcontroller_table_getter(self):
        self.assertNotIn("self.tableView", self.controller)
        self.assertIn("[self.table reloadData]", self.controller)

    def test_no_legacy_social_rat_cycle_or_diagnostic_actions(self):
        combined = ROOT_PLIST.read_text() + self.controller + self.cells
        resource_names = {path.name for path in (PREFS / "Resources").iterdir() if path.is_file()}
        self.assertFalse(resource_names & {
            "discord@2x.png", "discord@3x.png", "reddit@2x.png", "reddit@3x.png",
            "telegram@2x.png", "telegram@3x.png", "twitter@2x.png", "twitter@3x.png",
        })
        for forbidden in (
            "CCNMTelegramCell",
            "CCNMDiscordCell",
            "CCNMTwitterCell",
            "CCNMRedditCell",
            "showHelpAlert:",
            "enable2gGSM",
            "enableLTE",
            "enable5gNRStandAlone",
            "confirmSameValueBandWrite",
            "confirmColdBandRemovalWrite",
            "confirmLTEB1BandWrite",
            "confirmNR78BandWrite",
            "Clear Saved Probe State",
        ):
            self.assertNotIn(forbidden, combined)

    def test_ui_has_no_direct_modem_write(self):
        for forbidden in (
            "setActiveBandInfo",
            "_CTServerConnectionSetRATSelection",
            "setRatSelection:",
            "setRatSelectionMask:",
        ):
            self.assertNotIn(forbidden, self.controller + self.cells)

    def test_ui_is_wired_to_policy_and_truthful_serving_provider(self):
        for token in (
            '#import "CCNMN78PolicyController.h"',
            '#import "CCNMServingStatusProvider.h"',
            "configureProductionHandlers",
            "CCNMReadN78PolicyState()",
            "CCNMEnableN78Preference(completion)",
            "CCNMDisableN78Preference(completion)",
            "CCNMRecoverN78Preference",
            "refreshWithCompletion",
            "CCNMServingSummaryStaleKey",
            "CCNMServingSummarySampledAtMillisecondsKey",
        ):
            self.assertIn(token, self.controller)
        self.assertIn('summary[@"baselineValid"]', self.controller)
        self.assertIn('CCNMN78PolicySummaryErrorCodeKey', self.controller)
        self.assertIn('CCNMN78PolicySummaryErrorKey', self.controller)
        self.assertIn('POLICY_ERROR_DIAGNOSTIC_FORMAT', self.controller)

    def test_version_and_credits_are_formal(self):
        version_rows = [item for item in self.items if item.get("id") == "version"]
        self.assertEqual(len(version_rows), 1)
        self.assertEqual(version_rows[0].get("value"), control_version())
        self.assertIn("NoisyFlake", self.english["ABOUT_CREDITS_FOOTER"])
        self.assertIn("Nixuge", self.english["ABOUT_CREDITS_FOOTER"])
        self.assertIn("doimty", self.english["ABOUT_CREDITS_FOOTER"])

    def test_the_string_tables_and_the_bundle_reference_the_same_keys(self):
        """Both directions, because each failure mode ships something broken.

        A referenced-but-undefined key renders as the raw key on the device: the
        n78 alert showed a literal RESET_CARRIER_DEFAULTS button after the
        recovery action was renamed. A defined-but-unreferenced key is the other
        half of the same rename -- the retired RESTORE_ORIGINAL_BANDS and
        KNOWN_ORPHAN_* text stayed behind and still described replaying a saved
        baseline, which this package no longer does.
        """
        referenced = referenced_localization_keys()
        for table, name in ((self.english, "en"), (self.chinese, "zh-Hans")):
            missing = sorted(referenced - set(table))
            self.assertEqual(
                missing, [], f"{name} is missing keys the bundle asks for: {missing}"
            )
        unreferenced = sorted(set(self.english) - referenced)
        self.assertEqual(
            unreferenced,
            [],
            f"these keys are defined but nothing reads them: {unreferenced}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
