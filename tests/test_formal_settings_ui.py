#!/usr/bin/env python3
"""Static contracts for the formal localized Settings surface."""

from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "nrmanagerprefs"
ROOT_PLIST = PREFS / "Resources/Root.plist"
CHINESE = PREFS / "Resources/zh-Hans.lproj/NRManagerPrefs.strings"
CELLS = PREFS / "CCNMPreferencesCells.m"
CONTROLLER = PREFS / "CCNMRootListController.m"
CONTROL = ROOT / "control"

# Every localized string the bundle can ask for is a plain English-text key. The
# English text is both what an English device shows and the zh-Hans table key, so
# a missing translation degrades to readable English instead of a bare key name.
LOCALIZED_CALL = re.compile(r'CCNMPreferencesLocalizedString\(@"((?:[^"\\]|\\.)*)"\)')
# Dynamic-string values (dictionary values, formatKey assignments, alert title/
# message/button locals, display-values) that are passed into the localizer.
STRING_LITERAL = re.compile(r'@"((?:[^"\\]|\\.)*)"')

SOURCE_REPO = "https://github.com/doimty/NRManager"

# The only strings allowed to name a specific band. These report what the modem was
# measured on, so the band number is the fact being stated. Everything else in the
# table describes the policy, which since 1.6.0 is any subset of the allowed NR
# bands and therefore cannot name one.
SERVING_KEYS_THAT_MAY_NAME_A_BAND = frozenset({
    "NR n78",
    "NR n78 · %@",
})


def method_body(source: str, signature: str) -> str:
    """The body of the method whose implementation starts with `signature`.

    Skips a forward declaration: a private @interface repeats the signature and is
    terminated by `;`, so taking the first occurrence slices the class body instead
    of the method and every assertion below would silently check unrelated code.
    """
    start = 0
    while True:
        index = source.find(signature, start)
        if index < 0:
            raise AssertionError(f"no implementation of {signature}")
        brace = source.find("{", index)
        semicolon = source.find(";", index)
        if brace >= 0 and (semicolon < 0 or brace < semicolon):
            break
        start = index + len(signature)

    depth = 0
    for offset in range(brace, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:offset + 1]
    raise AssertionError(f"unbalanced braces after {signature}")


def code_lines(source: str) -> str:
    """`source` with comment-only and preprocessor lines dropped.

    An assertion that a symbol is absent has to be made against code, not prose.
    The UI explains in a comment which controller call ends in a modem write, and
    matching that sentence would fail the test on its own documentation.
    """
    kept = []
    for line in source.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("#"):
            continue
        kept.append(line)
    return "\n".join(kept)


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
    """All English-text keys the bundle actually asks for.

    English text is inline now: Root.plist carries it directly and the localizer
    calls pass English text as the key. This is the set the zh-Hans table must
    cover, and it is the set the definition-side check in
    test_the_string_tables_and_the_bundle_reference_the_same_keys relies on
    being complete enough not to flag legitimate prose.
    """
    keys = set()
    for source in sorted(PREFS.glob("*.m")) + sorted(PREFS.glob("*.h")):
        keys |= set(LOCALIZED_CALL.findall(source.read_text(encoding="utf-8")))
    for name in ("CCNMRootListController.m", "CCNMBandSelectionListController.m", "CCNMPreferencesCells.m"):
        source = (PREFS / name).read_text(encoding="utf-8")
        for literal in STRING_LITERAL.findall(source):
            if literal and literal[0].isupper() and not literal.startswith(("CCNM", "me.", "com.", "http")):
                keys.add(literal)

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("label", "subtitle", "footerText", "title", "value") \
                        and isinstance(value, str) and value and value[0].isupper() \
                        and not value.startswith("http"):
                    keys.add(value)
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(plistlib.loads(ROOT_PLIST.read_bytes()))
    return keys


class FormalSettingsUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plist = plistlib.loads(ROOT_PLIST.read_bytes())
        cls.items = cls.plist["items"]
        cls.chinese = strings_table(CHINESE)
        cls.cells = CELLS.read_text()
        cls.controller = CONTROLLER.read_text()

    def test_localization_key_parity_and_required_chinese(self):
        # English text is inline in Root.plist and the sources, so there is no
        # separate English table; zh-Hans must define every English text key.
        for key in (
            "NR band management and actual serving status",
            "NR Band Management",
            "Enable NR band management",
            "Current State",
            "Recovery & Maintenance",
            "Source code",
        ):
            self.assertIn(key, self.chinese)
            self.assertTrue(self.chinese[key].strip())
        self.assertEqual(self.chinese["Enable NR band management"], "启用 NR 频段管理")

    def test_generic_policy_copy_does_not_name_one_band(self):
        """Policy copy describes the mechanism; only measured state may name a band.

        1.6.0 generalised the feature to any subset of the allowed NR bands, but
        left this copy written for a hardcoded n78. On a device with n1 selected
        the applied-policy row therefore claimed n78, which reads as the modem
        ignoring the restriction rather than as a wording bug.
        """
        for table in (self.chinese,):
            for key, value in table.items():
                if key in SERVING_KEYS_THAT_MAY_NAME_A_BAND:
                    continue
                self.assertNotIn("n78", value.lower(), key)

    def test_serving_rows_may_still_name_the_measured_band(self):
        """n78 in a serving string is a measurement, not a policy claim."""
        for table in (self.chinese,):
            for key in SERVING_KEYS_THAT_MAY_NAME_A_BAND:
                self.assertIn("n78", table[key].lower(), key)

    def test_applied_policy_row_renders_the_recorded_target_bands(self):
        """The row must read the recorded band set, not a constant.

        Nothing else caught the 1.6.0 regression: the write, read-back and
        persistence paths were all correct and every test was green, because no
        assertion required this row to consume the value the policy stores.
        """
        body = method_body(
            self.controller,
            "- (NSString *)appliedPolicyDisplayValue:(NSDictionary *)policySummary",
        )
        self.assertIn("CCNMN78PolicySummaryTargetNRBandsKey", body)
        self.assertIn("Current NR allows only %@; LTE unchanged", body)
        self.assertIn("Last verified NR target %@; current modem bands unavailable", body)
        self.assertIn("Current NR %@ differs from recorded target %@", body)
        self.assertIn("NR band restriction was verified; recorded bands unavailable", body)
        self.assertIn("CCNMServingSummaryCapabilityActiveNRBandsKey", body)
        self.assertIn("CCNMServingSummaryCapabilityReadSuccessKey", body)
        self.assertIn("CCNMServingSummaryCapabilitySampledAtMillisecondsKey", body)
        self.assertIn("CCNMServingSummarySubscriptionUUIDKey", body)
        self.assertIn("caseInsensitiveCompare", body)
        self.assertIn("CCNMServingSummaryUnsafeOutstandingKey", body)
        self.assertIn("isEqualToArray", body)
        self.assertIn(
            "CCNMCanonicalNRSelection",
            body,
            "reuse the write path's canonicaliser so the row cannot show an"
            " ordering the policy would not have stored",
        )
        self.assertNotIn("APPLIED_VERIFIED_N78_ONLY", self.controller)
        for table in (self.chinese,):
            self.assertNotIn("APPLIED_VERIFIED_N78_ONLY", table)
            self.assertEqual(table["Current NR allows only %@; LTE unchanged"].count("%@"), 1)
            self.assertEqual(table["Last verified NR target %@; current modem bands unavailable"].count("%@"), 1)
            self.assertEqual(table["Current NR %@ differs from recorded target %@"].count("%@"), 2)
            self.assertNotIn("%@", table["NR band restriction was verified; recorded bands unavailable"])

    def test_applied_policy_row_recomputes_when_live_capability_changes(self):
        apply_policy = method_body(self.controller, "- (void)applyPolicySummary:")
        apply_serving = method_body(self.controller, "- (void)applyServingSummary:")
        refresh = method_body(self.controller, "- (void)beginServingRefresh {")
        for body in (apply_policy, apply_serving, refresh):
            self.assertIn("appliedPolicyDisplayValue", body)
            self.assertIn("self.servingSummary", body)
        self.assertNotIn("CCNMAReadStatus", self.controller)

    def test_pull_over_inspired_header_is_compact_and_independent(self):
        headers = [item for item in self.items if item.get("cellClass") == "CCNMHeaderCell"]
        self.assertEqual(len(headers), 1)
        self.assertIs(self.items[0], headers[0])
        self.assertEqual(headers[0].get("height"), 88.0)
        self.assertEqual(headers[0].get("label"), "NR Manager")
        self.assertEqual(headers[0].get("subtitle"), "NR band management and actual serving status")
        for token in (
            "constraintEqualToConstant:46.0",
            "preferredFontForTextStyle",
            "secondaryLabelColor",
            "adjustsFontForContentSizeCategory",
        ):
            self.assertIn(token, self.cells)

    def test_repository_links_are_exact_and_present_once(self):
        urls = [item.get("url") for item in self.items if item.get("url")]
        self.assertEqual(urls.count(SOURCE_REPO), 1)
        self.assertEqual(len(urls), 1)
        for item in self.items:
            if item.get("url"):
                self.assertEqual(item.get("url"), SOURCE_REPO)
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
            # The recovery action replays the saved baseline into the modem. 1.6.0
            # made it a carrier defaults reload, which needed no saved record and
            # so also worked when the baseline was missing; the target device
            # showed the reload does not actually widen the bands back, so the
            # reverse write is the mechanism again and the row is named for the
            # saved configuration it restores.
            "restoreSavedConfiguration",
        ):
            self.assertEqual(identifiers.count(identifier), 1)
        for retired in ("restoreOriginalBands", "resetCarrierDefaults"):
            self.assertNotIn(retired, identifiers)
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
        sources = code_lines(self.controller) + code_lines(self.cells)
        for forbidden in (
            "setActiveBandInfo",
            "_CTServerConnectionSetRATSelection",
            "setRatSelection:",
            "setRatSelectionMask:",
        ):
            self.assertNotIn(forbidden, sources)

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
        self.assertIn('%@\\n\\nError code: %@\\nDetails: %@', self.controller)
    def test_version_and_credits_are_formal(self):
        version_rows = [item for item in self.items if item.get("id") == "version"]
        self.assertEqual(len(version_rows), 1)
        self.assertEqual(version_rows[0].get("value"), control_version())
        self.assertIn(
            "Developed and maintained by the NR Manager project.",
            self.chinese,
        )

    def test_the_string_tables_and_the_bundle_reference_the_same_keys(self):
        """Both directions, because each failure mode ships something broken.

        A referenced-but-undefined text renders as raw text on the device, which is
        English (readable) rather than a bare key, but still means the Chinese
        translation is missing. A table entry that nothing can trigger is the other
        half: it rots without anyone noticing.
        """
        # Reference side: every Root.plist user-facing value and every direct
        # localized-string call argument must exist in the zh-Hans table.
        plist_texts = set()
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("label", "subtitle", "footerText", "title", "value") \
                            and isinstance(value, str) and value \
                            and not value.startswith("http") and not value.startswith("1.6"):
                        plist_texts.add(value)
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(self.plist["items"])
        call_args = set()
        for source in (self.controller, self.cells):
            call_args |= set(LOCALIZED_CALL.findall(source))
        for source_name in ("CCNMRootListController.m", "CCNMBandSelectionListController.m", "CCNMPreferencesCells.m"):
            source = (PREFS / source_name).read_text(encoding="utf-8")
            call_args |= set(LOCALIZED_CALL.findall(source))
        for text in sorted(plist_texts | call_args):
            self.assertIn(text, self.chinese, f"zh-Hans is missing: {text!r}")

        # Definition side: every table key must be triggerable from the sources or
        # the plist, and must be a plain English text (never a bare UPPER_SNAKE
        # key, which is exactly what used to leak onto the device).
        haystack = "\n".join([
            self.controller, self.cells,
            (PREFS / "CCNMBandSelectionListController.m").read_text(),
            ROOT_PLIST.read_text(),
        ])
        for key in self.chinese:
            self.assertRegex(key, r"[A-Za-z]")
            self.assertNotRegex(key, r"^[A-Z0-9_]{5,}$")
            self.assertIn(key, haystack)


if __name__ == "__main__":
    unittest.main(verbosity=2)
