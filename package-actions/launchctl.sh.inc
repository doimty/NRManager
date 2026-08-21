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

# Every launchctl call goes through launchctl_run, for two reasons that both
# showed up on the reporting device as a hung install.
#
# 1. dpkg's stdout is a pipe that the package manager reads, and it treats EOF on
#    that pipe as "the maintainer script is done". Any process that inherits it
#    and outlives the script keeps the install spinning even after the script has
#    exited. Six of the seven launchctl calls in these scripts were already
#    redirected; `bootstrap` was not, and that is exactly where the install
#    stopped. Detaching all three descriptors removes the whole class.
# 2. A maintainer script must not be able to hang the package manager, whatever
#    launchd does. Loading the daemon is explicitly best-effort -- the package is
#    fully functional without it -- and "best-effort" is not true of anything that
#    can block forever.
#
# The deadline is deliberately generous. It is a stuck-process backstop, not a
# performance limit.
LAUNCHCTL_DEADLINE_SECONDS=20
LAUNCHCTL_DELAY=''
# Set once any bounded call fails to answer. Every later call is then skipped
# instead of spending the deadline again.
#
# This is the second half of "a maintainer script must not hang the package
# manager", and the reporting device needed it: bounding each call individually
# still let one install spend 20s, and these scripts make up to six calls in a
# row. A launchd that stops answering one request answers none of the rest, so
# the honest reading of the first deadline is "launchd is not answering", not
# "that particular request was slow". Without this, worst case is the deadline
# times the number of calls; with it, the whole launchd section is bounded once.
LAUNCHCTL_STUCK=''

# A bounded wait needs a delay command. Absent one, the immediate load is skipped
# rather than run unbounded: the plist on disk already makes the job loadable at
# the next boot, so an unbounded call risks a hung install to save a reboot.
resolve_delay_command() {
    for _delay in /bin/sleep /usr/bin/sleep; do
        [ -e "$_delay" ] || continue
        "$_delay" 0 </dev/null >/dev/null 2>&1 || continue
        LAUNCHCTL_DELAY="$_delay"
        return 0
    done
    return 1
}

# Runs "$@" detached from dpkg's stdio, under LAUNCHCTL_DEADLINE_SECONDS.
# Returns the command's own exit status, 124 if the deadline expired or it died
# from a signal, or 125 if no delay command was resolved.
#
# The wait is a real wait() on our own child, not a kill -0 poll: an exited child
# stays a zombie until it is reaped, so kill -0 keeps succeeding after it is gone
# and a poll would sit out the full deadline on every success.
#
# Residual race, stated rather than hidden: the watchdog is cancelled by PID after
# the child is reaped, so a watchdog that wakes in that same instant could signal
# a recycled PID. The window is sub-millisecond and needs PID reuse inside the
# deadline. This is the standard shell timeout idiom and the alternatives need a
# writable temp path, which is worse in a root maintainer script.
# Residual risk, stated rather than hidden: if a child survives SIGKILL, the
# wait() below does not return and this script does not exit. On Darwin SIGKILL
# cannot be caught or blocked, so that requires a process wedged in an
# uninterruptible kernel path -- a state this project cannot construct on a test
# host and therefore cannot verify an escape hatch against. A bounded wait in
# POSIX sh needs a trapped signal from a third watchdog stage, and shipping that
# untested into a root maintainer script is the worse trade. The escalation below
# is verified: a child that ignores TERM is killed 2s later and the call returns
# 124.
launchctl_run() {
    [ -n "$LAUNCHCTL_DELAY" ] || return 125
    [ -z "$LAUNCHCTL_STUCK" ] || return 124
    "$@" </dev/null >/dev/null 2>&1 &
    _run_pid=$!
    (
        "$LAUNCHCTL_DELAY" "$LAUNCHCTL_DEADLINE_SECONDS"
        kill -TERM "$_run_pid" 2>/dev/null
        "$LAUNCHCTL_DELAY" 2
        kill -KILL "$_run_pid" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    _watchdog_pid=$!
    wait "$_run_pid" 2>/dev/null
    _run_status=$?
    kill -TERM "$_watchdog_pid" 2>/dev/null
    wait "$_watchdog_pid" 2>/dev/null || :
    # 128+signum. Any signal death means it did not finish on its own, which is
    # the same verdict as the deadline for every caller here.
    if [ "$_run_status" -ge 128 ]; then
        LAUNCHCTL_STUCK=1
        return 124
    fi
    return "$_run_status"
}

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
# cannot be handed bootout or bootstrap while probing. It is bounded like every
# other call, because a candidate that blocks on stdin or never returns would
# otherwise hang the install before the real work even starts. A candidate that
# hits the deadline is reported and skipped rather than used.
resolve_launchctl() {
    _launchctl_found=''
    _launchctl_report=''
    while IFS= read -r _candidate; do
        [ -n "$_candidate" ] || continue
        # Absent paths are skipped rather than reported: the first shipped probe
        # report listed twenty paths, eighteen of them plain ENOENT, and buried
        # the two entries that carried the diagnosis.
        [ -e "$_candidate" ] || continue
        launchctl_run "$_candidate" version
        _status=$?
        if [ "$_status" -eq 125 ]; then
            _launchctl_report="${_launchctl_report}${_launchctl_report:+, }${_candidate}(no delay command, cannot bound the call)"
            break
        fi
        if [ "$_status" -ne 126 ] && [ "$_status" -ne 127 ] && [ "$_status" -ne 124 ]; then
            _launchctl_found="$_candidate"
            break
        fi
        if [ "$_status" -eq 124 ]; then
            _launchctl_report="${_launchctl_report}${_launchctl_report:+, }${_candidate}(did not return within ${LAUNCHCTL_DEADLINE_SECONDS}s)"
            # Deliberately cleared, so probing continues to the next candidate.
            # The latch means "launchd is not answering", and `version` does not
            # ask launchd anything -- a candidate that hangs there is a bad or
            # wrong binary on that path, which says nothing about the next one.
            LAUNCHCTL_STUCK=''
        else
            _launchctl_report="${_launchctl_report}${_launchctl_report:+, }${_candidate}(exit ${_status})"
        fi
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
#
# Three outcomes, not two: 0 loaded, 1 not loaded, 2 launchd did not answer.
# Collapsing the third into "not loaded" is a false negative that reads as good
# news -- it would let a bootout that timed out be reported as a job successfully
# removed, which is the opposite of what happened.
launchd_job_is_loaded() {
    [ -n "$LAUNCHCTL" ] || return 2
    launchctl_run "$LAUNCHCTL" print "$LAUNCHD_TARGET"
    case $? in
        0) return 0 ;;
        124|125) return 2 ;;
        *) return 1 ;;
    esac
}

# Removes any loaded definition. Three outcomes, for the same reason
# launchd_job_is_loaded has three: 0 the job is known not to be loaded, 1 it is
# still loaded, 2 launchd did not answer so nothing is known.
#
# The distinction is not academic. Outcome 1 says a definition survived, which on
# a device whose jailbreak root has changed since the last install means launchd
# is holding a job whose executable no longer exists -- bootstrap returns EALREADY
# without replacing it, and every later check reports it as loaded. Outcome 2 says
# only that launchd stopped answering, and claiming a stale definition on that
# evidence would be inventing one.
launchd_bootout() {
    [ -n "$LAUNCHCTL" ] || return 2
    launchd_job_is_loaded
    case $? in
        1) return 0 ;;
        2) return 2 ;;
    esac
    launchctl_run "$LAUNCHCTL" bootout "$LAUNCHD_TARGET"
    launchd_job_is_loaded
    case $? in
        1) return 0 ;;
        2) return 2 ;;
    esac
    return 1
}
# --- end launchctl support ----------------------------------------------------
