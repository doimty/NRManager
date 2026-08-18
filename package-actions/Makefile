include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

TOOL_NAME = postinst prerm

postinst_FILES = postinst.m ../networkmanagerprefs/CCNMN78PolicyController.m
postinst_INSTALL_PATH = /DEBIAN
postinst_FRAMEWORKS = Foundation CoreFoundation
postinst_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
postinst_OBJCFLAGS += -fno-modules -fno-implicit-modules

prerm_FILES = prerm.m ../networkmanagerprefs/CCNMN78PolicyController.m
prerm_INSTALL_PATH = /DEBIAN
prerm_FRAMEWORKS = Foundation CoreFoundation
prerm_CFLAGS = -fobjc-arc -fvisibility=hidden -DCCNM_MAINTAINER_SCRIPT
prerm_OBJCFLAGS += -fno-modules -fno-implicit-modules

# Maintainer scripts run inside dpkg where libroothide.dylib is not loaded and
# @loader_path/.jbroot does not exist. CCNM_MAINTAINER_SCRIPT makes the policy
# module resolve the jailbreak root itself (roothide Bootstrap convention).
# Modules stay disabled so the roothide modulemap cannot auto-link the
# library, and neither the roothide library flag nor dynamic lookup is added,
# so the scripts have no unresolved jbroot symbols.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
# Keep the accepted roothide load-command shape (LC_DYLD_INFO_ONLY, no chained
# fixups) for these tools, same as every other roothide binary.
postinst_LDFLAGS += -Wl,-no_fixup_chains
prerm_LDFLAGS += -Wl,-no_fixup_chains
endif

include $(THEOS_MAKE_PATH)/tool.mk
