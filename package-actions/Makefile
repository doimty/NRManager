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
# ENOENT.
#
# Nothing is substituted into the launchd plist any more, on either lane. The
# plist ships complete: bare paths on roothide, because its launchctl is itself
# redirected and prepends the jailbreak root to every absolute path in the file on
# load, and /var/jb on rootless, because nothing there rewrites anything. The
# shell half now only resolves prefixes and hands them to these guards.
#
# What these guards do only reads and reports: policy state and the launchd
# contract. That is why these are still compiled — the policy model is shared
# with the Settings bundle and must not be reimplemented in shell.
#
# Running launchctl is not among them and cannot be. The reporting device
# returned EPERM from posix_spawn for the real <jbroot>/usr/bin/launchctl while
# the shell in the same dpkg run exec'd both `jbroot` and these guards without
# trouble, so the restriction is on this process rather than on the paths it
# tried. The candidate list and the probe that went with it lived here and are
# retired; the shell owns every launchctl invocation, in
# package-actions/launchctl.sh.inc.
TOOL_NAME = networkmanager-install-guard networkmanager-removal-guard

networkmanager-install-guard_FILES = postinst.m CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
networkmanager-install-guard_INSTALL_PATH = /usr/libexec
networkmanager-install-guard_FRAMEWORKS = Foundation CoreFoundation
networkmanager-install-guard_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
networkmanager-install-guard_OBJCFLAGS += -fno-modules -fno-implicit-modules

networkmanager-removal-guard_FILES = prerm.m CCNMDpkgVersion.c CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
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
