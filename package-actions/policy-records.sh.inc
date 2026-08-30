# --- policy record support ---------------------------------------------------
# The shell half of removal needs to answer two questions about the durable
# policy records: is a band configuration still in effect, and may these files be
# deleted. Nothing here signals a process or writes the modem.
#
# 1.6.0 put a `killall -9 CommCenter` adapter in this file, on the belief that it
# made the modem reload carrier defaults. The target device disproved it -- the
# bands stayed narrowed -- and the false success then authorised deleting the
# baseline, which is the only copy of the pre-enable configuration. The adapter
# and the dpkg version comparison that gated it are both gone. Do not reintroduce
# either: undoing a narrowed modem needs a reverse setActiveBandInfo: write, which
# only the Settings bundle can perform.

# Policy record paths. Bare, because the maintainer-script shell is the
# redirected process on roothide and /var/jb is baked into SCHEME_PREFIX on
# rootless -- the same reason PREFIX_PRIMARY is empty on one lane and a fixed
# string on the other. The compiled controller derives these through
# CCNMPolicyRoot(); this list is the shell's copy and the two must agree.
#
# n78-selection.plist is deliberately NOT here. It is the user's pending band
# choice, ordinary preference data rather than policy evidence, and it survives
# the off state on purpose so a selection can be edited while the feature is
# disabled. Deleting it as a policy record would throw away something the user
# typed.
POLICY_RECORD_DIR='/var/mobile/Library/Preferences'

# The baseline's own name, held in a variable because two different questions are
# asked about this one file -- is it present, and may it be deleted -- and a
# second hand-written copy of the name is how those two would come to disagree
# about which file they mean.
POLICY_BASELINE_BASENAME='com.doimty.nrmanager.n78-policy.baseline.plist'

policy_records() {
    printf '%s\n' \
        "${1}${POLICY_RECORD_DIR}/com.doimty.nrmanager.n78-policy.state.plist" \
        "${1}${POLICY_RECORD_DIR}/${POLICY_BASELINE_BASENAME}" \
        "${1}${POLICY_RECORD_DIR}/com.doimty.nrmanager.n78-policy.intent.plist" \
        "${1}${POLICY_RECORD_DIR}/com.doimty.nrmanager.n78-policy.inflight.plist" \
        "${1}${POLICY_RECORD_DIR}/com.doimty.nrmanager.n78-policy.removal-guard.plist"
}

# The baseline alone, because it is the one record whose presence is a decision.
# It holds the saved pre-enable band configuration, so it means both "an enable is
# still in effect" and "the way back still exists".
#
# Built from the shared basename rather than selected out of policy_records by
# line number: a sed -n '2p' would silently follow whatever became second after
# the next edit to that list, and it would put an external tool in a removal path
# that otherwise needs none.
policy_baseline_record() {
    printf '%s\n' "${1}${POLICY_RECORD_DIR}/${POLICY_BASELINE_BASENAME}"
}

policy_baseline_present() {
    while IFS= read -r _record; do
        [ -n "$_record" ] || continue
        [ -e "$_record" ] && return 0
    done <<POLICY_BASELINE_RECORDS
$(policy_baseline_record "$PREFIX_PRIMARY")
$(if [ -n "$PREFIX_FALLBACK" ]; then policy_baseline_record "$PREFIX_FALLBACK"; fi)
POLICY_BASELINE_RECORDS
    return 1
}

# Deliberately a separate list from policy_records: this file is the user's
# pending band choice, and it is discarded on a different condition (any removal)
# than the policy records (a removal with nothing left to undo). Merging the two
# lists is how one of those conditions would silently start applying to the other.
policy_band_selection() {
    printf '%s\n' \
        "${1}${POLICY_RECORD_DIR}/com.doimty.nrmanager.n78-selection.plist"
}

# Both cleanups share this: try every candidate root, report whether anything
# survived. ENOENT is success -- there is nothing to remove.
remove_listed_files() {
    _files_remain=0
    while IFS= read -r _file; do
        [ -n "$_file" ] || continue
        [ -e "$_file" ] || continue
        rm -f "$_file" 2>/dev/null
        [ -e "$_file" ] && _files_remain=1
    done
    [ "$_files_remain" -eq 0 ]
}

# Removes every policy record, and reports whether any survived. Called only when
# no baseline is on disk. While one exists the records are the only description of
# what was changed and how to change it back, and a reinstall needs them.
discard_policy_records() {
    remove_listed_files <<POLICY_RECORDS
$(policy_records "$PREFIX_PRIMARY")
$(if [ -n "$PREFIX_FALLBACK" ]; then policy_records "$PREFIX_FALLBACK"; fi)
POLICY_RECORDS
}

discard_band_selection() {
    remove_listed_files <<POLICY_BAND_SELECTION
$(policy_band_selection "$PREFIX_PRIMARY")
$(if [ -n "$PREFIX_FALLBACK" ]; then policy_band_selection "$PREFIX_FALLBACK"; fi)
POLICY_BAND_SELECTION
}
# --- end policy record support -----------------------------------------------
