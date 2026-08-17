include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

TOOL_NAME = postinst prerm

postinst_FILES = postinst.m ../networkmanagerprefs/CCNMN78PolicyController.m
postinst_INSTALL_PATH = /DEBIAN
postinst_FRAMEWORKS = Foundation CoreFoundation
postinst_CFLAGS = -fobjc-arc -fvisibility=hidden

prerm_FILES = prerm.m ../networkmanagerprefs/CCNMN78PolicyController.m
prerm_INSTALL_PATH = /DEBIAN
prerm_FRAMEWORKS = Foundation CoreFoundation
prerm_CFLAGS = -fobjc-arc -fvisibility=hidden

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
postinst_LIBRARIES = roothide
postinst_LDFLAGS += -undefined dynamic_lookup
prerm_LIBRARIES = roothide
prerm_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tool.mk
