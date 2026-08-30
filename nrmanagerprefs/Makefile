include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e
export VERSION = $(shell grep '^Version:' ../control | cut -d: -f2- | tr -d ' ')

BUNDLE_NAME = NRManagerPrefs

NRManagerPrefs_FILES = CCNMRootListController.m CCNMBandSelectionListController.m CCNMPreferencesCells.m CCNMN78PolicySupport.m CCNMN78PolicyController.m CCNMServingCellSampler.m CCNMServingStatusProvider.m CCNMAutomaticMaintenanceDecision.c
NRManagerPrefs_INSTALL_PATH = /Library/PreferenceBundles
NRManagerPrefs_FRAMEWORKS = Foundation UIKit
NRManagerPrefs_CFLAGS = -fobjc-arc

NRManagerPrefs_CFLAGS += -DNETWORK_MANAGER_VERSION=\"$(VERSION)\"

# For non-roothide: link to Preferences
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NRManagerPrefs_LDFLAGS += -framework Preferences
endif

# For roothide: link roothide library, use -undefined dynamic_lookup instead of private frameworks
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NRManagerPrefs_LIBRARIES = roothide
NRManagerPrefs_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	@echo "Version: $(VERSION)"
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NRManagerPrefs.plist$(ECHO_END)