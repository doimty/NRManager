include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e
export VERSION = $(shell grep '^Version:' ../control | cut -d: -f2- | tr -d ' ')

BUNDLE_NAME = NetworkManagerPrefs

NetworkManagerPrefs_FILES = CCNMRootListController.m CCNMPreferencesCells.m CCNMN78PolicyController.m CCNMServingCellSampler.m CCNMServingStatusProvider.m
NetworkManagerPrefs_INSTALL_PATH = /Library/PreferenceBundles
NetworkManagerPrefs_FRAMEWORKS = Foundation UIKit
NetworkManagerPrefs_CFLAGS = -fobjc-arc

NetworkManagerPrefs_CFLAGS += -DNETWORK_MANAGER_VERSION=\"$(VERSION)\"

# For non-roothide: link to Preferences
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NetworkManagerPrefs_LDFLAGS += -framework Preferences
endif

# For roothide: link roothide library, use -undefined dynamic_lookup instead of private frameworks
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetworkManagerPrefs_LIBRARIES = roothide
NetworkManagerPrefs_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	@echo "Version: $(VERSION)"
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NetworkManagerPrefs.plist$(ECHO_END)