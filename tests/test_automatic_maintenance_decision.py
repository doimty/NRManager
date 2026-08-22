import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "networkmanagerprefs" / "CCNMAutomaticMaintenanceDecision.c"
HEADER_DIR = ROOT / "networkmanagerprefs"

HARNESS = r'''
#include <stdbool.h>
#include <stdint.h>
#include "CCNMAutomaticMaintenanceDecision.h"

static CCNMAutomaticMaintenanceSample sample(
    bool valid, bool stale, bool unsafe, CCNMAutomaticMaintenanceRAT rat, int band) {
    CCNMAutomaticMaintenanceSample value = { valid, stale, unsafe, rat, band };
    return value;
}

static CCNMAutomaticMaintenanceInput base_input(void) {
    CCNMAutomaticMaintenanceInput input = {0};
    input.policyEnabled = true;
    input.capabilityCompatible = true;
    input.targetBand = 78;
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

    return 0;
}
'''


class AutomaticMaintenanceDecisionTests(unittest.TestCase):
    def test_decision_module_is_compiled_into_both_consumers(self):
        source_name = "networkmanagerprefs/CCNMAutomaticMaintenanceDecision.c"
        prefs_makefile = (ROOT / "networkmanagerprefs" / "Makefile").read_text()
        daemon_makefile = (ROOT / "maintenance-daemon" / "Makefile").read_text()
        self.assertIn("CCNMAutomaticMaintenanceDecision.c", prefs_makefile)
        self.assertIn("../networkmanagerprefs/CCNMAutomaticMaintenanceDecision.c", daemon_makefile)

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
