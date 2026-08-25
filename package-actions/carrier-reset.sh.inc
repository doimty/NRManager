# --- carrier configuration reset support ------------------------------------
# The device-observed recovery primitive is deliberately literal: two separate
# invocations of `killall -9 CommCenter`. Do not collapse these into one call or
# replace them with a reverse BandInfo setter. The shell owns this adapter in the
# maintainer-script environment because the compiled guard cannot reliably exec
# helpers on the reporting roothide device.

CARRIER_KILLALL=''
CARRIER_KILLALL_REPORT=''
DPKG_COMMAND=''
DPKG_REPORT=''

# Same candidate discipline as launchctl and killall, and for the same reason:
# PATH is inherited from dpkg and this runs as root.
dpkg_candidates() {
    printf '%s\n' \
        /usr/bin/dpkg \
        /bin/dpkg \
        /usr/local/bin/dpkg
    if [ -n "$PREFIX_FALLBACK" ]; then
        printf '%s\n' \
            "${PREFIX_FALLBACK}/usr/bin/dpkg" \
            "${PREFIX_FALLBACK}/bin/dpkg"
    fi
}

resolve_dpkg_command() {
    [ -n "$DPKG_COMMAND" ] && return 0
    DPKG_REPORT=''
    while IFS= read -r _candidate; do
        [ -n "$_candidate" ] || continue
        [ -x "$_candidate" ] || continue
        DPKG_COMMAND="$_candidate"
        return 0
    done <<DPKG_CANDIDATES
$(dpkg_candidates)
DPKG_CANDIDATES
    DPKG_REPORT='no fixed dpkg path is executable'
    return 1
}

# Version ordering, delegated to the tool that defines it. dpkg spells upgrade
# and downgrade with the same action, so this has to be an ordering question
# rather than a string test, and dpkg's own comparison is the only answer that is
# correct for epochs, revisions and non-numeric parts. Bounded, because it is
# still a child process on the removal path.
#
# bounded_run, not launchctl_run: dpkg is not launchd, and a dpkg that does not
# answer says nothing about whether launchd will. Routing it through the latching
# wrapper made a hung comparison suppress the carrier reset that follows it.
version_is_at_least() {
    [ -n "$DPKG_COMMAND" ] || resolve_dpkg_command || return 2
    bounded_run "$DPKG_COMMAND" --compare-versions "$1" ge "$2"
}

# Policy record paths. Bare, because the maintainer-script shell is the
# redirected process on roothide and /var/jb is baked into SCHEME_PREFIX on
# rootless -- the same reason PREFIX_PRIMARY is empty on one lane and a fixed
# string on the other. The compiled controller derives these through
# CCNMPolicyRoot(); this list is the shell's copy and the two must agree.
#
# n78-selection.plist is deliberately NOT here. It is the user's pending band
# choice, ordinary preference data rather than policy evidence, and it survives
# the off state on purpose so a selection can be edited while the feature is
# disabled. Deleting it on removal would throw away something the user typed.
carrier_policy_records() {
    printf '%s\n' \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.state.plist" \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.baseline.plist" \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.intent.plist" \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.inflight.plist" \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.removal-guard.plist"
}

# Deliberately a separate list from carrier_policy_records: this file is the
# user's pending band choice, and it is discarded on a different condition (any
# removal) than the policy records (a confirmed reset). Merging the two lists is
# how one of those conditions would silently start applying to the other.
carrier_band_selection() {
    printf '%s\n' \
        "${1}/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-selection.plist"
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

carrier_killall_candidates() {
    printf '%s\n' \
        /usr/bin/killall \
        /bin/killall \
        /usr/sbin/killall \
        /sbin/killall \
        /basebin/killall
    if [ -n "$PREFIX_FALLBACK" ]; then
        printf '%s\n' \
            "${PREFIX_FALLBACK}/usr/bin/killall" \
            "${PREFIX_FALLBACK}/bin/killall" \
            "${PREFIX_FALLBACK}/basebin/killall"
    fi
}

resolve_carrier_killall() {
    CARRIER_KILLALL=''
    CARRIER_KILLALL_REPORT=''
    while IFS= read -r _candidate; do
        [ -n "$_candidate" ] || continue
        [ -e "$_candidate" ] || continue
        CARRIER_KILLALL="$_candidate"
        return 0
    done <<CARRIER_KILLALL_CANDIDATES
$(carrier_killall_candidates)
CARRIER_KILLALL_CANDIDATES
    CARRIER_KILLALL_REPORT='no fixed killall path exists'
    return 1
}

# Removes every policy record, and reports whether any survived. Called only
# after a confirmed reset: on an unconfirmed one the records are the only
# remaining evidence that the modem was left narrowed, so a reinstall needs them.
discard_policy_records() {
    remove_listed_files <<CARRIER_POLICY_RECORDS
$(carrier_policy_records "$PREFIX_PRIMARY")
$(if [ -n "$PREFIX_FALLBACK" ]; then carrier_policy_records "$PREFIX_FALLBACK"; fi)
CARRIER_POLICY_RECORDS
}

discard_band_selection() {
    remove_listed_files <<CARRIER_BAND_SELECTION
$(carrier_band_selection "$PREFIX_PRIMARY")
$(if [ -n "$PREFIX_FALLBACK" ]; then carrier_band_selection "$PREFIX_FALLBACK"; fi)
CARRIER_BAND_SELECTION
}

# Returns 0 only when both invocations completed with status 0. A status of 1
# means killall did not find CommCenter, so the observed two-kill sequence was not
# completed and the caller must not claim that carrier defaults were reloaded.
#
# bounded_run for the same reason as the version comparison: killall is not
# launchd. Worst case here is two deadlines rather than one, and that is the
# correct trade -- the second invocation is the device-observed primitive, so it
# must not be skipped on the strength of the first one being slow.
carrier_reset_defaults() {
    [ -n "$LAUNCHCTL_DELAY" ] || return 125
    [ -n "$CARRIER_KILLALL" ] || resolve_carrier_killall || return 126

    bounded_run "$CARRIER_KILLALL" -9 CommCenter
    _carrier_first_status=$?
    [ "$_carrier_first_status" -eq 0 ] || return "$_carrier_first_status"

    "$LAUNCHCTL_DELAY" 0.25 </dev/null >/dev/null 2>&1 || return 125

    bounded_run "$CARRIER_KILLALL" -9 CommCenter
    _carrier_second_status=$?
    [ "$_carrier_second_status" -eq 0 ] || return "$_carrier_second_status"
    return 0
}
# --- end carrier configuration reset support --------------------------------
