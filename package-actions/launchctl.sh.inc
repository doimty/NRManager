# --- launchctl support, shared by postinst and prerm --------------------------
# Substituted into both maintainer scripts by
# scripts/patch-maintenance-launchd.py, at the insertion point named in that
# script's placeholder table. One copy, because two hand-maintained copies of exec
# logic in two maintainer scripts is how the halves drift apart.
#
# Why the shell runs launchctl and the compiled guards do not
# ----------------------------------------------------------
# The guards tried, through a probe table of twenty candidate paths, and the
# reporting device answered conclusively:
#
#   probed <jbroot>/bin/launchctl(spawn errno 1),
#          <jbroot>/usr/bin/launchctl(spawn errno 1);
#          18 other probed paths do not exist
#
# errno 1 is EPERM from posix_spawn itself, and the second path is the real
# 113664-byte binary. Two further facts from the same dpkg run identify the
# cause. The guard saw every bare path as ENOENT while jbroot-absolute paths
# resolved, so it has no path redirection; and this shell exec'd both `jbroot`
# and the guard without trouble. On roothide the redirection and the exec
# exemption both come from basebin/bootstrap.dylib via DYLD_INSERT_LIBRARIES, and
# a compiled maintainer-script child does not get it. So the restriction is on
# the guard's process, not on the paths it tried, and no probe table could have
# fixed it. The shell is the injected half, so the shell execs.
#
# Independently confirmed from the device shell: `command -v launchctl` is
# /usr/bin/launchctl, and `launchctl bootstrap system /Library/LaunchDaemons/...`
# with a bare plist path loaded the job and printed a correct single-prefix
# program path.
#
# Candidate paths, not $PATH
# --------------------------
# PATH is inherited from dpkg and this runs as root, so resolving through it
# would let whatever is first in PATH be exec'd as root. The paths below are
# fixed, and bare ones are correct here precisely because this process is the
# redirected one.
launchctl_candidates() {
    printf '%s\n' \
        /usr/bin/launchctl \
        /bin/launchctl \
        /usr/sbin/launchctl \
        /sbin/launchctl \
        /basebin/launchctl
    # roothide keeps a jbroot-aware copy in basebin, and the jbroot-absolute
    # forms cover a shell that turns out not to be redirected after all.
    if [ -n "$PREFIX_FALLBACK" ]; then
        printf '%s\n' \
            "${PREFIX_FALLBACK}/usr/bin/launchctl" \
            "${PREFIX_FALLBACK}/bin/launchctl" \
            "${PREFIX_FALLBACK}/basebin/launchctl"
    fi
}

LAUNCHCTL=''
LAUNCHCTL_REPORT=''

# Resolves LAUNCHCTL, or returns nonzero with LAUNCHCTL_REPORT naming what was
# tried and how it refused.
#
# No -x test anywhere. That is access(X_OK), and on this platform the X_OK check
# is routed through an exec-authorization hook that returned EPERM for the real
# launchctl binary and for a freshly unpacked helper. It is not a usable oracle,
# so the exec attempt is the authority and 126/127 -- the shell's own "found but
# not executable" and "not found" -- are the only refusals.
#
# `version` is side-effect free, so a wrong binary sitting on a candidate path
# cannot be handed bootout or bootstrap while probing.
resolve_launchctl() {
    _launchctl_found=''
    _launchctl_report=''
    while IFS= read -r _candidate; do
        [ -n "$_candidate" ] || continue
        # Absent paths are skipped rather than reported: the first shipped probe
        # report listed twenty paths, eighteen of them plain ENOENT, and buried
        # the two entries that carried the diagnosis.
        [ -e "$_candidate" ] || continue
        "$_candidate" version >/dev/null 2>&1
        _status=$?
        if [ "$_status" -ne 126 ] && [ "$_status" -ne 127 ]; then
            _launchctl_found="$_candidate"
            break
        fi
        _launchctl_report="${_launchctl_report}${_launchctl_report:+, }${_candidate}(exit ${_status})"
    done <<LAUNCHCTL_CANDIDATES
$(launchctl_candidates)
LAUNCHCTL_CANDIDATES
    LAUNCHCTL="$_launchctl_found"
    LAUNCHCTL_REPORT="$_launchctl_report"
    [ -n "$LAUNCHCTL" ]
}

# launchd is the authority on whether the job is loaded, not the exit code of the
# command that tried to load it. `bootstrap` returns 37 (EALREADY) for a job that
# is already bootstrapped, which is a success for our purposes and was exactly
# what the device reported.
launchd_job_is_loaded() {
    [ -n "$LAUNCHCTL" ] || return 1
    "$LAUNCHCTL" print "$LAUNCHD_TARGET" >/dev/null 2>&1
}

# Best-effort removal of any loaded definition. Returns nonzero only when the job
# is still loaded afterwards, so "was not loaded to begin with" is a success.
launchd_bootout() {
    [ -n "$LAUNCHCTL" ] || return 1
    launchd_job_is_loaded || return 0
    "$LAUNCHCTL" bootout "$LAUNCHD_TARGET" >/dev/null 2>&1
    if launchd_job_is_loaded; then
        return 1
    fi
    return 0
}
# --- end launchctl support ----------------------------------------------------
