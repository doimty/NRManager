include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

TOOL_NAME = postinst prerm

postinst_FILES = postinst.m CCNMLaunchctlProbe.c CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
postinst_INSTALL_PATH = /DEBIAN
postinst_FRAMEWORKS = Foundation CoreFoundation
postinst_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
postinst_OBJCFLAGS += -fno-modules -fno-implicit-modules

prerm_FILES = prerm.m CCNMDpkgVersion.c CCNMLaunchctlProbe.c CCNMMaintainerEnvironment.m ../networkmanagerprefs/CCNMN78PolicySupport.m ../networkmanagerprefs/CCNMN78PolicyController.m
prerm_INSTALL_PATH = /DEBIAN
prerm_FRAMEWORKS = Foundation CoreFoundation
prerm_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
prerm_OBJCFLAGS += -fno-modules -fno-implicit-modules

# Maintainer scripts run inside dpkg where libroothide.dylib is not loaded and
# @loader_path/.jbroot does not exist. CCNMMaintainerEnvironment resolves the
# rootless install prefix or the unique roothide Bootstrap root, and the policy
# module uses the same scheme-aware convention. Modules stay disabled so the
# roothide modulemap cannot auto-link the library; the scripts have no
# unresolved jbroot symbols.

include $(THEOS_MAKE_PATH)/tool.mk
