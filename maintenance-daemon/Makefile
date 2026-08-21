include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

TOOL_NAME = networkmanager-maintenance

networkmanager-maintenance_FILES = main.m \
	CCNMDaemonRoot.c \
	CCNMDaemonRoot.m \
	../networkmanagerprefs/CCNMN78PolicySupport.m \
	../networkmanagerprefs/CCNMN78PolicyReader.m \
	../networkmanagerprefs/CCNMServingStatusProvider.m \
	../networkmanagerprefs/CCNMServingCellSampler.m \
	../networkmanagerprefs/CCNMAutomaticMaintenanceDecision.c \
	../networkmanagerprefs/CCNMAutomaticMaintenanceRecord.m
networkmanager-maintenance_FRAMEWORKS = CoreTelephony Foundation
networkmanager-maintenance_CFLAGS = -fobjc-arc -DCCNM_MAINTENANCE_DAEMON
networkmanager-maintenance_INSTALL_PATH = /usr/libexec

# libroothide is deliberately not linked, on any lane.
#
# Its install name is @loader_path/.jbroot/usr/lib/libroothide.dylib, which needs
# either a .jbroot symlink beside this binary or a process that already has the
# library loaded. A launchd daemon has neither: launchd applies no bootstrap
# injection. The reporting device showed the consequence exactly --
#
#   dyld: Library not loaded: @loader_path/.jbroot/usr/lib/libroothide.dylib
#     tried: <jbroot>/usr/libexec/.jbroot/usr/lib/libroothide.dylib (no such
#     file), /usr/local/lib/... (no such file), /usr/lib/... (no such file)
#
# with launchd reporting runs = 108, successive crashes = 108, last exit reason =
# OS_REASON_DYLD. The job had never once started.
#
# The Control Center and Preferences bundles link it safely because they load into
# already-injected processes. A daemon is the opposite situation, so it recovers
# the install prefix from its own executable path instead: CCNMDaemonRoot.m.
# -DCCNM_MAINTENANCE_DAEMON is what switches the shared policy sources onto that
# path, and it must be set on every lane, not only roothide -- rootless installs
# under /var/jb and needs the same prefix, just a different value.
#
# There is deliberately no lane-specific link flag. The roothide branch used to
# carry `-undefined dynamic_lookup` next to the libroothide link, and it outlived
# the library. It was never needed: this tool references nothing outside
# libSystem, libobjc, Foundation, CoreFoundation and CoreTelephony, and it links
# clean without it. Worse, it masked the one class of defect this release exists
# to fix. Dropping CCNMDaemonRoot.m from the file list above links successfully
# with the flag and fails with `Undefined symbols: _CCNMDaemonRootedPath` without
# it, so a genuinely missing symbol would have shipped as a binary that loads and
# then dies when dyld has to bind it -- the same runtime-only failure shape as the
# libroothide crash, from a different cause. It also demoted _objc_msgSend to the
# flat namespace in the arm64 slice of the shipped build.
#
# Removing it changes this binary's dyld fixup format from LC_DYLD_INFO_ONLY to
# LC_DYLD_CHAINED_FIXUPS, because chained fixups cannot encode a flat-namespace
# lookup and the flag was forcing the old format. That is accepted here and only
# here. The chained-fixups suspicion on this project concerns *injected* bundles;
# the two guards next door are exec'd tools that ship chained fixups and both ran
# on the reporting iOS 15.1.1 device, which is what makes this trade evidenced
# rather than assumed. A masked missing symbol is a real defect; the fixup format
# on an exec'd tool is not.
#
# If a private framework is ever genuinely needed here, declare it; do not
# reintroduce a blanket flag.

include $(THEOS_MAKE_PATH)/tool.mk