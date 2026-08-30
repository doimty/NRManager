import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "nrmanagerprefs" / "CCNMAutomaticMaintenanceDecision.c"
HEADER_DIR = ROOT / "nrmanagerprefs"

HARNESS = r'''
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "CCNMAutomaticMaintenanceDecision.h"

static CCNMAutomaticMaintenanceSample sample(
    bool valid, bool stale, bool unsafe, CCNMAutomaticMaintenanceRAT rat, int band) {
    CCNMAutomaticMaintenanceSample value = { valid, stale, unsafe, rat, band };
    return value;
}

static const int single_band_78[] = { 78 };
static const int bands_41_and_78[] = { 41, 78 };
static const int bands_with_zero[] = { 78, 0 };
static const int bands_with_negative[] = { -1, 78 };

static CCNMAutomaticMaintenanceInput base_input(void) {
    CCNMAutomaticMaintenanceInput input = {0};
    input.policyEnabled = true;
    input.capabilityCompatible = true;
    input.targetBands = single_band_78;
    input.targetBandCount = 1;
    input.nowMilliseconds = 1000;
    return input;
}

int main(void) {
    CCNMAutomaticMaintenanceInput input = base_input();

    input.previous = sample(false, false, false, CCNMAutomaticMaintenanceRATUnknown, 0);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 3);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceAwaitEvidence) return 1;

    input.previous = sample(true, true, false, CCNMAutomaticMaintenanceRATLTE, 3);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceAwaitEvidence) return 2;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 1);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 3);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceAwaitEvidence) return 3;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 3);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceCorrectOnce) return 4;
    input.dropRecordedForCurrentSample = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceDropRecorded) return 24;
    input.dropRecordedForCurrentSample = false;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 41);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 41);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceCorrectOnce) return 5;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceTargetStable) return 6;

    input.unsafeOutstanding = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopUnsafe) return 7;
    input.unsafeOutstanding = false;

    input.capabilityCompatible = false;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 8;
    input.capabilityCompatible = true;

    input.verificationPending = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceVerificationPending) return 9;
    input.verificationPending = false;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 3);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 3);
    input.attemptUsedForDrop = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopAttemptExhausted) return 10;
    input.attemptUsedForDrop = false;

    input.cooldownUntilMilliseconds = 1001;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceDeferCooldown) return 11;
    input.cooldownUntilMilliseconds = 0;

    input.operationInProgress = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceDeferBusy) return 12;
    input.operationInProgress = false;

    input.policyEnabled = false;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceDisabled) return 13;

    input.policyEnabled = true;
    input.previous.unsafeOutstanding = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopUnsafe) return 14;

    /* A chosen subset means every band in it is a legitimate resting place. */
    input = base_input();
    input.targetBands = bands_41_and_78;
    input.targetBandCount = 2;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 41);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 41);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceTargetStable) return 15;

    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceTargetStable) return 16;

    /* A band outside the selection still deserves one correction. */
    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 79);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 79);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceCorrectOnce) return 17;

    /* Membership is not enough: the RAT must still be NR. */
    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 41);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATLTE, 41);
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceCorrectOnce) return 18;

    /* An absent or malformed selection is not something the daemon may maintain. */
    input = base_input();
    input.previous = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);
    input.current = sample(true, false, false, CCNMAutomaticMaintenanceRATNR, 78);

    input.targetBandCount = 0;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 19;

    input.targetBands = NULL;
    input.targetBandCount = 1;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 20;

    input.targetBands = bands_with_zero;
    input.targetBandCount = 2;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 21;

    input.targetBands = bands_with_negative;
    input.targetBandCount = 2;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 22;

    /* An unusable selection outranks a pending verification: refusing to act is
       always available, but acting on an unknown target never is. */
    input.verificationPending = true;
    if (CCNMEvaluateAutomaticMaintenance(input) != CCNMAutomaticMaintenanceStopIncompatible) return 23;

    return 0;
}
'''


class AutomaticMaintenanceDecisionTests(unittest.TestCase):
    def test_decision_module_is_compiled_into_both_consumers(self):
        source_name = "nrmanagerprefs/CCNMAutomaticMaintenanceDecision.c"
        root_makefile = (ROOT / "Makefile").read_text()
        prefs_makefile = (ROOT / "nrmanagerprefs" / "Makefile").read_text()
        self.assertIn(source_name, root_makefile)
        self.assertIn("CCNMAutomaticMaintenanceDecision.c", prefs_makefile)

    def test_the_target_is_a_set_not_a_single_band(self):
        """A single int cannot express a chosen subset.

        Keeping membership inside the pure C module matters: this is the only part
        of the maintenance decision that has a harness, so moving the test into
        the Objective-C caller would move it out of coverage.
        """
        header = (ROOT / "nrmanagerprefs" / "CCNMAutomaticMaintenanceDecision.h").read_text()
        self.assertIn("const int *targetBands", header)
        self.assertIn("size_t targetBandCount", header)
        self.assertNotIn("int targetBand;", header)

    def test_the_daemon_passes_the_recorded_selection(self):
        daemon = (ROOT / "maintenance-daemon" / "main.m").read_text()
        self.assertNotIn("input.targetBand = 78", daemon)
        self.assertIn("CCNMN78PolicySummaryTargetNRBandsKey", daemon)
        self.assertIn("input.targetBandCount", daemon)

    def test_the_daemon_feeds_same_context_record_state_into_each_decision(self):
        daemon = (ROOT / "maintenance-daemon" / "main.m").read_text()
        evaluate = daemon.index("CCNMEvaluateAutomaticMaintenance(input)")
        window = daemon[daemon.rfind("CCNMAutomaticMaintenanceInput input", 0, evaluate):evaluate]
        self.assertIn("CCNMAReadRecord()", window)
        self.assertIn("CCNMARecordMatchesCurrentContext", window)
        self.assertIn("input.verificationPending", window)
        self.assertIn("CCNMARecordVerificationPendingKey", window)
        self.assertIn("input.dropRecordedForCurrentSample", window)
        self.assertIn("CCNMARecordDropGenerationKey", window)
        self.assertIn("CCNMARecordDropRATKey", window)
        self.assertIn("CCNMARecordDropBandKey", window)
        self.assertIn("input.attemptUsedForDrop", window)
        self.assertIn("CCNMARecordAttemptConsumedKey", window)
        self.assertIn("input.cooldownUntilMilliseconds", window)
        self.assertIn("CCNMARecordCooldownUntilKey", window)
        self.assertIn("input.nowMilliseconds", window)

    def test_pure_decision_model(self):
        self.assertTrue(SOURCE.exists(), SOURCE)
        with tempfile.TemporaryDirectory() as temporary:
            harness = pathlib.Path(temporary) / "automatic_maintenance_harness.c"
            executable = pathlib.Path(temporary) / "automatic_maintenance_harness"
            harness.write_text(textwrap.dedent(HARNESS))
            compiled = subprocess.run(
                [
                    "gcc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(HEADER_DIR),
                    str(harness),
                    str(SOURCE),
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
