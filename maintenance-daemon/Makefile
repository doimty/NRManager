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
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
networkmanager-maintenance_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tool.mk