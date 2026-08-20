include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

# These are no longer dpkg maintainer scripts. postinst and prerm are shell
# scripts generated from postinst.sh.in / prerm.sh.in, and they delegate here.
#
# The split exists because the privileged half of the work cannot be done from a
# compiled binary on roothide. The jbroot path redirection and the sandbox
# exemption both come from basebin/bootstrap.dylib, injected through
# DYLD_INSERT_LIBRARIES. The reporting device showed a compiled maintainer script
# running as euid 0 that could stat and read inside the jbroot but got EPERM on
# every write and on every child exec, and saw bare paths like /bin/launchctl as
# ENOENT. Substituting @JBROOT@ is therefore done in shell, the way roothide's
# own packages do it (plutil -xml, then sed with $(jbroot)).
#
# What remains here only reads and reports: policy state, the launchd contract,
# and the launchctl load attempt. That is why these are still compiled — the
# policy model is shared with the Settings bundle and must not be reimplemented
# in shell.
TOOL_NAME = networkmanager-install-guard networkmanager-removal-guard

networkmanager-install-guard_FILES = postinst.m CCNMLaunchctlProbe.c CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
networkmanager-install-guard_INSTALL_PATH = /usr/libexec
networkmanager-install-guard_FRAMEWORKS = Foundation CoreFoundation
networkmanager-install-guard_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
networkmanager-install-guard_OBJCFLAGS += -fno-modules -fno-implicit-modules

networkmanager-removal-guard_FILES = prerm.m CCNMDpkgVersion.c CCNMLaunchctlProbe.c CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
networkmanager-removal-guard_INSTALL_PATH = /usr/libexec
networkmanager-removal-guard_FRAMEWORKS = Foundation CoreFoundation
networkmanager-removal-guard_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
networkmanager-removal-guard_OBJCFLAGS += -fno-modules -fno-implicit-modules

# libroothide is still not linked. roothideinit.dylib derives the jbroot from its
# own load path and asserts on @loader_path/.jbroot, which does not exist beside
# an installed helper, so linking it would abort at load time. The guards resolve
# the install prefix themselves and never need to write. Modules stay disabled so
# the roothide modulemap cannot auto-link the library.

include $(THEOS_MAKE_PATH)/tool.mk
