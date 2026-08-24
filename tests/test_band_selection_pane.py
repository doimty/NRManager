#!/usr/bin/env python3
"""Contracts for the NR band selection pane (work items 12-15).

The pane is the only place a user expresses a band selection, and it sits one tap
away from the switch that writes to the modem. The assertions here are about that
boundary: which functions may be reached from which handler, and that the domain
the pane offers is computed by the same code the write path validates against.

The band-number classifier is exercised as a compiled C model rather than by
reading the source, because its whole job is a numeric judgement.
"""

import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PREFS = ROOT / "networkmanagerprefs"
PANE = PREFS / "CCNMBandSelectionListController.m"
PANE_HEADER = PREFS / "CCNMBandSelectionListController.h"
BAND_SUPPORT = PREFS / "CCNMNRBandSupport.h"
CELLS = PREFS / "CCNMPreferencesCells.m"
CELLS_HEADER = PREFS / "CCNMPreferencesCells.h"
CONTROLLER = PREFS / "CCNMN78PolicyController.m"
READER = PREFS / "CCNMN78PolicyReader.m"
POLICY_HEADER = PREFS / "CCNMN78PolicyController.h"
ROOT_PLIST = PREFS / "Resources/Root.plist"
ENGLISH = PREFS / "Resources/en.lproj/NetworkManagerPrefs.strings"
CHINESE = PREFS / "Resources/zh-Hans.lproj/NetworkManagerPrefs.strings"

# Every entry point that can reach the modem or the durable policy records.
# A row tap must reach none of them.
POLICY_WRITE_ENTRY_POINTS = (
    "CCNMEnableN78Preference",
    "CCNMDisableN78Preference",
    "CCNMRecoverN78Preference",
    "CCNMRecoverKnownOrphanedN78WithCompletion",
    "CCNMArmN78PolicyRemovalGuard",
    "CCNMClearN78PolicyRemovalGuardIfSafe",
    "CCNMWriteSelectedNRBands",
)

MODEM_SETTERS = (
    "setActiveBandInfo",
    "_CTServerConnectionSetRATSelection",
    "setRatSelection:",
    "setRatSelectionMask:",
)


def code_only(text: str) -> str:
    """The source with comments removed, so prose cannot satisfy or break a check.

    Assertions about what the code does must read the code. This file bans several
    tokens precisely because the surrounding comments explain at length why they are
    absent, and a commented-out gate must never be able to satisfy an assertion.
    String literals are preserved, because the localization checks are about text.

    Same scanner as tests/test_serving_status_provider.py. Duplicated rather than
    shared, because every test module in this repository stands alone.
    """
    out = []
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if character == '"':
            out.append(character)
            index += 1
            while index < length:
                out.append(text[index])
                if text[index] == "\\":
                    if index + 1 < length:
                        out.append(text[index + 1])
                        index += 2
                        continue
                elif text[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = length if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = length if end < 0 else end + 2
            continue
        out.append(character)
        index += 1
    return "".join(out)


def makefile_code_only(text: str) -> str:
    """The same idea for a Makefile, whose comments use ``#``.

    A commented-out source line must not read as compiled.
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith("#")
    )


def method_bodies(source: str) -> dict[str, str]:
    """Map an Objective-C method's selector-ish signature to its body text.

    Keyed by the first selector part, which is unique within this file. Bodies run
    from the signature to the first closing brace in column 1, which is the style
    every method in this repository is written in.
    """
    bodies = {}
    lines = source.splitlines()
    starts = [
        index for index, line in enumerate(lines)
        if re.match(r"^[-+]\s*\(", line)
    ]
    for start in starts:
        name = re.search(r"\)\s*([A-Za-z_][A-Za-z0-9_]*)", lines[start])
        if not name:
            continue
        end = start
        while end < len(lines) and lines[end] != "}":
            end += 1
        bodies[name.group(1)] = "\n".join(lines[start:end + 1])
    return bodies


def strings_table(path: pathlib.Path) -> dict[str, str]:
    table = {}
    pattern = re.compile(r'^"([A-Z0-9_]+)"\s*=\s*"(.*)";$')
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        match = pattern.match(stripped)
        if not match:
            raise AssertionError(f"{path.name}:{number} unparsable localization line")
        if match.group(1) in table:
            raise AssertionError(f"{path.name}:{number} duplicate key {match.group(1)}")
        table[match.group(1)] = match.group(2)
    return table


BAND_RANGE_HARNESS = r'''
#include <stdio.h>
#include "CCNMNRBandSupport.h"

static const long long sub6_only[] = { 41, 78 };
static const long long mmwave_only[] = { 257, 260 };
static const long long mixed[] = { 78, 260 };
static const long long with_invalid[] = { 260, 0 };
static const long long above_ceiling[] = { 2048 };

int main(void) {
    /* FR1 / FR2 split is by band number, which 3GPP allocates by range. */
    if (CCNMClassifyNRBandRange(1) != CCNMNRBandRangeSub6) return 1;
    if (CCNMClassifyNRBandRange(78) != CCNMNRBandRangeSub6) return 2;
    if (CCNMClassifyNRBandRange(256) != CCNMNRBandRangeSub6) return 3;
    if (CCNMClassifyNRBandRange(257) != CCNMNRBandRangeMillimeterWave) return 4;
    if (CCNMClassifyNRBandRange(261) != CCNMNRBandRangeMillimeterWave) return 5;

    /* Out of range is Unknown, never silently one of the two real answers. */
    if (CCNMClassifyNRBandRange(0) != CCNMNRBandRangeUnknown) return 6;
    if (CCNMClassifyNRBandRange(-1) != CCNMNRBandRangeUnknown) return 7;
    if (CCNMClassifyNRBandRange(CCNM_NR_MAXIMUM_BAND_IDENTIFIER + 1) != CCNMNRBandRangeUnknown) return 8;
    if (CCNMClassifyNRBandRange(CCNM_NR_MAXIMUM_BAND_IDENTIFIER) != CCNMNRBandRangeMillimeterWave) return 9;

    /* The mmWave-only warning must fire only when every band is mmWave. */
    if (CCNMNRSelectionIsMillimeterWaveOnly(sub6_only, 2) != 0) return 10;
    if (CCNMNRSelectionIsMillimeterWaveOnly(mmwave_only, 2) == 0) return 11;
    if (CCNMNRSelectionIsMillimeterWaveOnly(mixed, 2) != 0) return 12;

    /* An unclassifiable band is not mmWave, so it must suppress the warning
       rather than being counted as one more mmWave entry. */
    if (CCNMNRSelectionIsMillimeterWaveOnly(with_invalid, 2) != 0) return 13;
    if (CCNMNRSelectionIsMillimeterWaveOnly(above_ceiling, 1) != 0) return 14;

    /* No bands is not a coverage warning; it is a refusal handled elsewhere. */
    if (CCNMNRSelectionIsMillimeterWaveOnly(mmwave_only, 0) != 0) return 15;
    if (CCNMNRSelectionIsMillimeterWaveOnly(NULL, 2) != 0) return 16;

    return 0;
}
'''


class BandRangeModelTests(unittest.TestCase):
    def test_compiled_band_range_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = pathlib.Path(temporary) / "band_range_harness.c"
            executable = pathlib.Path(temporary) / "band_range_harness"
            harness.write_text(textwrap.dedent(BAND_RANGE_HARNESS))
            compiled = subprocess.run(
                ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                 "-I", str(PREFS), str(harness), "-o", str(executable)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_band_ceiling_matches_the_policy_that_would_hold_the_band(self):
        """A band this classifier accepts must be one the policy could store.

        The policy constant is file-local in each mirror on purpose, so the two are
        pinned here instead of shared through a header. If either mirror's ceiling
        moves, this fails rather than letting the pane offer a band the write path
        would reject.
        """
        declared = re.search(r"#define CCNM_NR_MAXIMUM_BAND_IDENTIFIER (\d+)",
                             code_only(BAND_SUPPORT.read_text()))
        self.assertIsNotNone(declared)
        for mirror in (CONTROLLER, READER):
            found = re.search(r"static const long long CCNMMaximumBandIdentifier = (\d+);",
                              code_only(mirror.read_text()))
            self.assertIsNotNone(found, mirror.name)
            self.assertEqual(declared.group(1), found.group(1), mirror.name)

    def test_the_classifier_observes_nothing(self):
        """Static band facts only. Anything device-shaped belongs in the sampler.

        Read past the comments: the header's scope note names NRARFCN and the
        sampler header in order to say what this one deliberately is not.
        """
        text = code_only(BAND_SUPPORT.read_text())
        for forbidden in ("CTCellMonitor", "CoreTelephony", "NRARFCN", "GSCN",
                          "#import", "CCNMServingStatusSupport.h"):
            self.assertNotIn(forbidden, text, forbidden)


class PaneWriteBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = code_only(PANE.read_text())
        cls.bodies = method_bodies(cls.source)

    def test_the_extractor_found_the_methods_under_test(self):
        """Guard against the scoping assertions below passing on an empty string."""
        for name in ("toggleBandSelection", "saveBandSelection", "commitSelection",
                     "reloadModel", "warningsForSelection"):
            self.assertIn(name, self.bodies)
            self.assertGreater(len(self.bodies[name].splitlines()), 3, name)

    def test_a_row_tap_reaches_no_policy_write_and_no_modem_setter(self):
        """The plan's required assertion for this work item.

        Row selection is in-memory state only. If a write ever moves into the
        toggle handler, a user browsing checkmarks would be writing durable state
        with every tap, and the reason the pane is safe to leave in an
        uncommitted state disappears.
        """
        toggle = self.bodies["toggleBandSelection"]
        for entry_point in POLICY_WRITE_ENTRY_POINTS + MODEM_SETTERS:
            self.assertNotIn(entry_point, toggle, entry_point)

    def test_the_preference_write_happens_in_exactly_one_place(self):
        self.assertEqual(self.source.count("CCNMWriteSelectedNRBands("), 1)
        self.assertIn("CCNMWriteSelectedNRBands(", self.bodies["commitSelection"])

    def test_the_pane_never_reaches_a_policy_operation_or_the_modem(self):
        """Turning the feature on stays on the parent pane, behind the switch."""
        for entry_point in POLICY_WRITE_ENTRY_POINTS:
            if entry_point == "CCNMWriteSelectedNRBands":
                continue
            self.assertNotIn(entry_point, self.source, entry_point)
        for setter in MODEM_SETTERS:
            self.assertNotIn(setter, self.source, setter)

    def test_the_pane_does_not_start_a_sampler_run(self):
        """Sampling is an async private-API call behind a cross-process lock with an
        unsafe-outstanding latch, already owned by the parent pane. A second owner
        could leave that latch set, which blocks the write path the user is heading
        towards, so the pane reads the cached summary only.
        """
        self.assertNotIn("refreshWithCompletion", self.source)
        self.assertIn("currentSummary", self.source)

    def test_saving_revalidates_instead_of_trusting_the_row_state(self):
        save = self.bodies["saveBandSelection"]
        self.assertIn("[self canSave]", save)
        commit = self.bodies["commitSelection"]
        self.assertIn("CCNMReadSelectedNRBands()", commit,
                      "the saved selection must be read back, not assumed")
        self.assertIn("CCNMReadN78PolicyState()", commit,
                      "a delayed warning confirmation must re-check policy state")


class PaneDomainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = code_only(PANE.read_text())
        cls.bodies = method_bodies(cls.source)

    def test_the_domain_comes_from_the_write_path_not_a_lookalike(self):
        """The pane must not compute its own intersection.

        Two implementations of "which bands may be chosen" would let the pane offer
        a band an enable then refuses, which the user experiences as the toggle
        failing for no stated reason.
        """
        self.assertIn("CCNMSelectableNRBandDomain(", self.bodies["domainFromSummary"])
        for stray in ("isSubsetOfSet", "NSMutableArray *domain", "intersectSet:"):
            self.assertNotIn(stray, self.source, stray)

    def test_the_shared_domain_helpers_are_exported_and_share_an_implementation(self):
        header = POLICY_HEADER.read_text()
        self.assertIn("CCNMSelectableNRBandDomain", header)
        self.assertIn("CCNMValidateNRBandSelectionAgainstDomain", header)
        controller = CONTROLLER.read_text()
        # One intersection routine, reached by both the dictionary-level write path
        # and the array-level UI entry point.
        self.assertEqual(controller.count("CCNMSelectableNRDomainFromArrays("), 3)

    def test_editing_is_refused_while_the_policy_is_on(self):
        """While enabled, live active NR *is* the applied selection.

        A domain read in that state would be the current selection rather than what
        the system originally allowed, so it would shrink with every apply. The
        pane refuses instead of narrowing silently.
        """
        availability = self.bodies["availabilityForPolicySummary"]
        self.assertIn("CCNMRecoveryStateEnabledWithBaseline", availability)
        self.assertIn("CCNMRequestedModeN78Preferred", availability)
        self.assertIn("CCNMRecoveryStateClean", availability)
        self.assertIn("BAND_UNAVAILABLE_ENABLED", self.source)

    def test_a_stored_band_outside_the_domain_is_reported_not_silently_kept(self):
        """The stranding case: a stored band the current SIM no longer offers.

        Dropping it without saying so leaves the user with a selection that differs
        from what they last saved and no way to see why.
        """
        self.assertIn("droppedStoredBands", self.source)
        self.assertIn("BAND_GROUP_FOOTER_DROPPED", self.source)

    def test_the_pane_does_not_substitute_a_default_for_an_absent_applied_target(self):
        """CCNMN78PolicySummaryTargetNRBandsKey is absent unless a settled enabled
        state exists, and its documented contract is that a reader must treat that
        as "no selection in effect" rather than assuming the shipped default."""
        for stray in ("@[ @78 ]", "@[@78]", "containsObject:@78"):
            self.assertNotIn(stray, self.source, stray)

    def test_domain_requires_fresh_capability_evidence(self):
        body = self.bodies["domainFromSummary"]
        for token in (
            "CCNMServingSummaryCapabilitySampledAtMillisecondsKey",
            "CCNMBandSelectionFreshnessLifetimeMilliseconds",
        ):
            self.assertIn(token, body + self.source, token)
        self.assertIn("sampledAt > now", body + self.source)
        self.assertIn("now - sampledAt", body + self.source)
        self.assertIn("Capability evidence and serving-cell evidence are separate", PANE.read_text())

    def test_recovery_state_takes_priority_over_requested_mode(self):
        body = self.bodies["availabilityForPolicySummary"]
        recovery_gate = body.index("CCNMRecoveryStateClean")
        requested_mode = body.index("CCNMN78PolicySummaryRequestedModeKey")
        self.assertLess(recovery_gate, requested_mode)

    def test_an_unedited_pane_is_compared_against_what_it_actually_offered(self):
        """The save row must not enable itself on a pane nobody touched.

        The stored selection and the working set live in different spaces: working is
        stored narrowed to the current domain. Comparing across that boundary reports
        an edit whenever a stored band has dropped out, because such a band can never
        be in working. The domain is the live active list narrowed by supported, so it
        shrinks on its own when the modem's active set changes, which made the save
        row turn itself on after the pane was merely re-entered. Both sides must be
        the domain-narrowed set.

        This also keeps the row honest in the other direction: the dropped bands are
        reported in the group footer, which states they will not be saved again, so a
        save that omits them is not a silent narrowing.
        """
        self.assertIn("workingSelectionDiffersFromBaseline", self.bodies)
        reload_model = self.bodies["reloadModel"]
        self.assertIn("self.baselineSelection = [working.allObjects", reload_model)
        self.assertNotIn("self.baselineSelection = stored", reload_model)
        # The raw stored array may seed working and dropped, and nothing else.
        self.assertNotIn("savedSelection", self.source)
        differs = self.bodies["workingSelectionDiffersFromBaseline"]
        self.assertIn("self.baselineSelection", differs)
        # Both operands are already canonical, so a re-sort here would mean one of
        # them is some other array.
        self.assertNotIn("sortedArrayUsingSelector", differs)
        self.assertIn("workingSelectionDiffersFromBaseline", self.bodies["canSave"])
        self.assertIn("workingSelectionDiffersFromBaseline", self.bodies["statusText"])
        self.assertIn("BAND_GROUP_FOOTER_DROPPED", self.source)

    def test_the_default_selection_is_not_presented_as_an_explicit_save(self):
        self.assertIn("CCNMHasStoredSelectedNRBands", self.source)
        status = self.bodies["statusText"]
        self.assertIn("hasExplicitSavedSelection", status)
        self.assertIn("BAND_STATUS_UNSAVED_FORMAT", status)

    def test_enabled_state_displays_the_applied_policy_target(self):
        reload_model = self.bodies["reloadModel"]
        self.assertIn("CCNMN78PolicySummaryTargetNRBandsKey", reload_model)
        self.assertIn("CCNMCanonicalNRSelection", reload_model)
        self.assertIn("showingAppliedSelection", reload_model)
        self.assertIn("hidingSelectionForRecovery", reload_model)
        self.assertIn("appliedSelection", reload_model)


class PaneServingBandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = code_only(PANE.read_text())
        cls.bodies = method_bodies(cls.source)

    def test_the_serving_band_is_only_adopted_from_a_fresh_successful_nr_sample(self):
        """It drives a warning about losing the current connection, so a guess is
        worse than saying nothing."""
        adopt = self.bodies["adoptServingCellFromSummary"]
        for token in ("CCNMServingSummarySuccessKey", "CCNMServingSummaryStaleKey",
                      "CCNMServingStateNRN78", "CCNMServingStateNROther"):
            self.assertIn(token, adopt, token)

    def test_excluding_the_serving_band_warns_only_when_one_was_measured(self):
        warnings = self.bodies["warningsForSelection"]
        self.assertIn("self.servingNRBand", warnings)
        self.assertIn("BAND_WARNING_EXCLUDES_SERVING_FORMAT", warnings)
        self.assertIn("BAND_WARNING_MMWAVE_ONLY", warnings)

    def test_a_row_does_not_claim_a_frequency_for_an_unmeasured_band(self):
        """A band number alone does not determine a frequency; that needs the 3GPP
        band table, which this project does not transcribe. Only the band actually
        being served has a measured frequency, so only it may show one.

        The ban is on the code: -detailForBand:'s comment names NRARFCN to record
        why the plan's original approach was dropped.
        """
        detail = self.bodies["detailForBand"]
        self.assertIn("self.servingFrequencyMHz", detail)
        self.assertIn("self.servingNRBand", detail)
        self.assertNotIn("NRARFCN", self.source)


class PaneCellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cells = code_only(CELLS.read_text())
        cls.bodies = method_bodies(cls.cells)

    def test_the_checkmark_is_specifier_state_not_cell_state(self):
        """Multi-select, so PSTableCell's -setChecked: radio-group machinery is the
        wrong owner, and the accessory type is reset when Preferences refreshes a
        recycled cell.

        The band cell's comment names the accessory type to record why a glyph is
        used instead, so the ban has to look at the code alone.
        """
        header = code_only(CELLS_HEADER.read_text())
        self.assertIn("CCNMPreferenceCheckedKey", header)
        self.assertIn("CCNMBandSelectionCell", header)
        self.assertNotIn("UITableViewCellAccessoryCheckmark", self.cells)
        self.assertNotIn("[self setChecked:", self.cells)

    def test_a_recycled_band_cell_cannot_inherit_the_previous_row_state(self):
        """Every visual attribute is assigned on every refresh, including its
        negative case. A stale checkmark is a false claim about what will be
        written to the modem."""
        body = self.bodies["refreshCellContentsWithSpecifier"]
        # The band cell is the last of the three to define this selector.
        band_refresh = self.cells.rsplit("- (void)refreshCellContentsWithSpecifier:", 1)[1]
        self.assertIn("checkmarkView.hidden = !checked", band_refresh)
        self.assertIn("PSEnabledKey", band_refresh)
        self.assertGreater(len(body.splitlines()), 3)

    def test_a_checked_row_stays_visible_without_sf_symbols(self):
        band_refresh = self.cells.rsplit("- (void)refreshCellContentsWithSpecifier:", 1)[1]
        self.assertIn("BAND_SELECTED_FALLBACK_MARK", band_refresh)

    def test_custom_cells_choose_accessibility_height_themselves(self):
        pane = code_only(PANE.read_text())
        self.assertNotIn("PSTableCellHeightKey", pane)
        self.assertIn("preferredHeightForWidth", self.cells)

    def test_a_code_built_specifier_carries_a_cell_class_not_its_name(self):
        """Regression: this crashed Preferences on entering the pane.

        Root.plist may spell a cell class as a string because Preferences' plist
        loader replaces it with NSClassFromString before building the specifier.
        Nothing performs that conversion for a specifier built in code, and
        +[PSTableCell cellClassForSpecifier:] returns the property as it was stored.
        PSListController then sends +isSubclassOfClass: to it while laying out the
        row, which an NSString does not answer, and the unrecognised selector
        aborts Settings.

        Scanned across the whole bundle rather than just this pane, because the
        mistake is available to any future controller that builds a specifier in
        code, and no build-time or packaging gate can see it: the string compiles,
        links, signs, and passes every verifier this repository has.
        """
        for source in sorted(PREFS.glob("*.m")):
            text = code_only(source.read_text())
            for value in re.findall(r"setProperty:([^\n]*?)\s+forKey:PSCellClassKey", text):
                value = value.strip()
                self.assertTrue(
                    value == "cellClass" or value.endswith(".class"),
                    f"{source.name}: PSCellClassKey must be given a Class, got {value!r}",
                )
            for name in ("CCNMStatusCell", "CCNMBandSelectionCell", "CCNMHeaderCell",
                         "CCNMRepositoryLinkCell"):
                self.assertNotIn(
                    f'setProperty:@"{name}"', text,
                    f"{source.name}: {name} must be passed as a Class, not a name",
                )

        pane = code_only(PANE.read_text())
        self.assertIn("static void CCNMSetCellClass(PSSpecifier *specifier, Class cellClass)",
                      pane)
        self.assertEqual(pane.count("forKey:PSCellClassKey"), 1,
                         "PSCellClassKey must only be written by CCNMSetCellClass")
        self.assertEqual(pane.count("CCNMSetCellClass("), 4)

    def test_the_group_header_and_footer_cell_keys_stay_strings(self):
        """The sibling keys that look identical but are not.

        Preferences resolves PSHeaderCellClassGroupKey and PSFooterCellClassGroupKey
        with NSClassFromString on the framework side, so those two want a name.
        Converting them alongside PSCellClassKey would break them in the opposite
        direction, so the distinction is pinned rather than left to memory.
        """
        for source in sorted(PREFS.glob("*.m")):
            text = code_only(source.read_text())
            for key in ("PSHeaderCellClassGroupKey", "PSFooterCellClassGroupKey"):
                for value in re.findall(rf"setProperty:([^\n]*?)\s+forKey:{key}", text):
                    self.assertFalse(value.strip().endswith(".class"),
                                     f"{source.name}: {key} takes a class name, not a Class")

    def test_a_code_built_specifier_gets_its_id_as_a_property(self):
        """Regression: the save row could never be re-enabled after a valid change.

        -[PSSpecifier identifier] reads propertyForKey:@"id" and falls back to
        @"label", then @"key", then -name. PSSpecifier declares no _identifier
        storage, so the whole notion of an identifier is that property. A specifier
        that never has it written answers the fallback -- a localized display name --
        so -specifierForID: cannot match the ID the caller asked for, and every
        refresh keyed on that lookup silently does nothing.

        Writing PSIDKey makes the first branch of the getter hit, and it is what
        Preferences itself does: +[PSSpecifier deleteButtonSpecifierWithName:target:
        action:] sets the ID with setProperty:forKey:@"id" and never goes through
        -setIdentifier:. Scanned across the bundle for the same reason as the
        cell-class check: no build or packaging gate can see this, because assigning
        the property compiles and links fine.
        """
        for source in sorted(PREFS.glob("*.m")):
            text = code_only(source.read_text())
            self.assertNotRegex(
                text, r"\.identifier\s*=[^=]",
                f"{source.name}: write a specifier ID with setProperty:forKey:PSIDKey",
            )
            self.assertNotIn(
                "setIdentifier:", text,
                f"{source.name}: write a specifier ID with setProperty:forKey:PSIDKey",
            )

        pane = code_only(PANE.read_text())
        self.assertIn(
            "static void CCNMSetSpecifierID(PSSpecifier *specifier, NSString *identifier)",
            pane)
        self.assertEqual(pane.count("forKey:PSIDKey"), 1,
                         "PSIDKey must only be written by CCNMSetSpecifierID")
        # Five call sites plus the definition: status, one band row, save, the
        # unavailable row, and the shared group builder.
        self.assertEqual(pane.count("CCNMSetSpecifierID("), 6)

    def test_a_group_built_with_group_specifier_with_id_also_writes_the_property(self):
        """+groupSpecifierWithID: routes through -setIdentifier:, so it needs the same fix.

        A group whose ID does not resolve is not merely unfindable: group specifiers
        are how the framework delimits sections, and code that looks one up by ID to
        retitle or refoot it would edit the wrong object.
        """
        pane = code_only(PANE.read_text())
        builder = method_bodies(pane)["groupSpecifierWithID"]
        self.assertIn("CCNMSetSpecifierID(group, identifier)", builder)

    def test_replacing_the_model_goes_through_the_framework_setter(self):
        """Regression: the same bug from the other side.

        _specifiersByID and the group index array are rebuilt only by
        -prepareSpecifiersMetadata, which runs from -viewDidLoad, -setSpecifiers: and
        -reloadSpecifiers. Assigning the ivar directly leaves both describing the
        previous build, so an ID lookup can return an object the table no longer
        holds; -reloadSpecifier: finds rows with -indexOfObject: and PSSpecifier does
        not override -isEqual:, so that comparison is by pointer and the reload is
        dropped. The stale group indices are the more dangerous half, because row
        counts are computed from them and this pane's row count varies with the
        capability evidence.

        The one permitted direct assignment is the -specifiers getter, which
        PSListController calls from within its own -viewDidLoad before it runs
        -prepareSpecifiersMetadata; using the setter there would re-enter the getter.
        """
        pane = code_only(PANE.read_text())
        bodies = method_bodies(pane)
        for name, body in bodies.items():
            if name in ("specifiers", "commitRebuiltSpecifiers"):
                continue
            self.assertNotRegex(
                body, r"_specifiers\s*=[^=]",
                f"-{name} must replace the model with -setSpecifiers:",
            )
        self.assertIn("[self setSpecifiers:rebuilt]", bodies["commitRebuiltSpecifiers"])
        for name in ("rebuildFromWorld", "commitSelection"):
            self.assertIn("commitRebuiltSpecifiers", bodies[name],
                          f"-{name} must commit through the setter")

    def test_the_two_refreshed_rows_are_held_not_looked_up_by_id(self):
        """The refresh must not depend on an ID lookup at all.

        Writing the ID property fixes the matching, but the lookup can still answer
        with a specifier from an earlier build. Holding the objects the pane just
        built removes the failure mode instead of narrowing it. The references are
        weak so that a replaced model yields nil -- a skipped refresh, which shows --
        rather than a stale object, which does not.
        """
        pane = code_only(PANE.read_text())
        self.assertNotIn("specifierForID:", pane)
        for line in ("@property (nonatomic, weak, nullable) PSSpecifier *currentStatusSpecifier;",
                     "@property (nonatomic, weak, nullable) PSSpecifier *currentSaveSpecifier;"):
            self.assertIn(line, pane)
        refresh = method_bodies(pane)["refreshStatusAndSaveRows"]
        self.assertIn("self.currentStatusSpecifier", refresh)
        self.assertIn("self.currentSaveSpecifier", refresh)
        self.assertIn("CCNMPreferenceValueKey", refresh)
        self.assertIn("PSEnabledKey", refresh)

    def test_an_untouched_factory_default_does_not_claim_to_be_unsaved(self):
        """Three states, because the save button has three.

        Band 78 alone is what a user who has never opened this pane has. Reporting it
        as "not saved yet" points at a button that is correctly disabled, since there
        is no edit to save. Only a selection that differs from what is stored is
        unsaved.
        """
        pane = code_only(PANE.read_text())
        status = method_bodies(pane)["statusText"]
        self.assertIn("BAND_STATUS_DEFAULT_FORMAT", status)
        self.assertNotIn("|| !self.hasExplicitSavedSelection", status)
        for table in (strings_table(ENGLISH), strings_table(CHINESE)):
            self.assertIn("BAND_STATUS_DEFAULT_FORMAT", table)
            self.assertIn("%@", table["BAND_STATUS_DEFAULT_FORMAT"])

    def test_the_save_handler_does_not_claim_disabled_rows_still_dispatch(self):
        """The re-check is right; the reason recorded for it was not.

        -[PSTableCell setCellEnabled:] clears userInteractionEnabled, so a disabled
        PSButtonCell does not dispatch. The guard stays because the state it reads
        can change after the row was rendered, which is a real race; the retracted
        claim would have justified it with framework behaviour that does not exist.
        """
        pane = PANE.read_text()
        self.assertNotIn("can still dispatch its action", pane)
        save = method_bodies(code_only(pane))["saveBandSelection"]
        self.assertIn("if (![self canSave])", save)


class PanePackagingTests(unittest.TestCase):
    def test_the_pane_is_compiled_into_the_preference_bundle(self):
        makefile = makefile_code_only((PREFS / "Makefile").read_text())
        self.assertIn("CCNMBandSelectionListController.m", makefile)

    def test_the_pane_is_reachable_from_the_root_pane(self):
        import plistlib
        items = plistlib.loads(ROOT_PLIST.read_bytes())["items"]
        links = [item for item in items
                 if item.get("detail") == "CCNMBandSelectionListController"]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].get("cell"), "PSLinkCell")
        self.assertEqual(links[0].get("id"), "bandSelection")

    def test_the_pane_header_states_the_two_load_bearing_constraints(self):
        header = PANE_HEADER.read_text()
        self.assertIn("never writes to the modem", header)
        self.assertIn("clean", header)


class PaneLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.english = strings_table(ENGLISH)
        cls.chinese = strings_table(CHINESE)
        # Comment-stripped so a commented-out call cannot demand a key, while the
        # string literals the keys live in are preserved.
        cls.source = code_only(PANE.read_text()) + code_only(CELLS.read_text())

    def test_every_key_the_pane_asks_for_exists_in_both_locales(self):
        used = set(re.findall(r'CCNMPreferencesLocalizedString\(@"([A-Z0-9_]+)"\)', self.source))
        self.assertGreater(len(used), 20)
        for key in sorted(used):
            self.assertIn(key, self.english, key)
            self.assertIn(key, self.chinese, key)
            self.assertTrue(self.chinese[key].strip(), key)

    def test_format_strings_agree_between_locales(self):
        """A locale with a different placeholder count crashes -stringWithFormat:
        rather than degrading."""
        for key in sorted(set(self.english) & set(self.chinese)):
            self.assertEqual(self.english[key].count("%@"), self.chinese[key].count("%@"), key)

    def test_validation_failures_are_localized_before_reaching_the_ui(self):
        validation = method_bodies(self.source)["validationFailureForWorkingSelection"]
        for key in ("BAND_SAVE_EMPTY", "BAND_SAVE_OUTSIDE_DOMAIN", "BAND_SAVE_WHOLE_DOMAIN"):
            self.assertIn(key, validation, key)
        self.assertNotIn("return failure;", validation)

    def test_the_pane_strings_say_that_saving_writes_nothing_to_the_modem(self):
        """The pane's whole safety story is that it is inert until the switch is
        used. If that sentence is dropped, a user has no way to know."""
        self.assertIn("modem", self.english["BAND_SAVE_FOOTER"])
        self.assertIn("基带", self.chinese["BAND_SAVE_FOOTER"])
        self.assertIn("LTE", self.english["BAND_WARNING_MMWAVE_ONLY"])
        self.assertIn("LTE", self.chinese["BAND_WARNING_MMWAVE_ONLY"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
