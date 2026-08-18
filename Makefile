include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

BUNDLE_NAME = NetworkManager
NetworkManager_BUNDLE_EXTENSION = bundle
NetworkManager_FILES = CCNetworkManager.x networkmanagerprefs/CCNMN78PolicyController.m networkmanagerprefs/CCNMServingStatusProvider.m networkmanagerprefs/CCNMServingCellSampler.m
NetworkManager_FRAMEWORKS = CoreTelephony Foundation UIKit
NetworkManager_INSTALL_PATH = /Library/ControlCenter/Bundles

NetworkManager_CFLAGS += -fobjc-arc
NetworkManager_CFLAGS += "-Wno-error=objc-method-access"

# For non-roothide: link to ControlCenterUIKit
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NetworkManager_LDFLAGS += -framework ControlCenterUIKit
endif

# For roothide: link roothide library, use -undefined dynamic_lookup instead of private frameworks
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetworkManager_LIBRARIES = roothide
NetworkManager_LDFLAGS += -undefined dynamic_lookup
endif

after-install::
	install.exec "killall -9 SpringBoard"

include $(THEOS_MAKE_PATH)/bundle.mk
SUBPROJECTS += networkmanagerprefs
SUBPROJECTS += package-actions
include $(THEOS_MAKE_PATH)/aggregate.mk
