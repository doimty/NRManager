include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

BUNDLE_NAME = NetworkManager
NetworkManager_BUNDLE_EXTENSION = bundle
NetworkManager_FILES = CCNetworkManager.x \
	livecc/Sources/CCNMLiveBandText.c \
	livecc/Sources/CCNMLiveServingPaths.m \
	networkmanagerprefs/CCNMServingStatusProvider.m \
	networkmanagerprefs/CCNMServingCellSampler.m \
	networkmanagerprefs/CCNMAutomaticMaintenanceDecision.c
NetworkManager_FRAMEWORKS = CoreFoundation CoreTelephony Foundation UIKit
NetworkManager_INSTALL_PATH = /Library/ControlCenter/Bundles

NetworkManager_CFLAGS += -fobjc-arc
NetworkManager_CFLAGS += "-Wno-error=objc-method-access"
NetworkManager_CFLAGS += -Ilivecc/include -Inetworkmanagerprefs
NetworkManager_CFLAGS += -DCCNMServingStatusProvider=CCNMLiveServingStatusProvider
NetworkManager_CFLAGS += -DCCNMCellMonitorAsyncState=CCNMLiveCellMonitorAsyncState
NetworkManager_CFLAGS += -DCCNM_SERVING_USE_LIVECC_NAMESPACE=1
NetworkManager_CFLAGS += -DCCNM_LIVE_MAIN_BUNDLE=1
NetworkManager_CFLAGS += -DNetworkManagerLiveViewController=CCNetworkManagerViewController
NetworkManager_CFLAGS += -DNetworkManagerLiveModule=CCNetworkManager

# Resolve ControlCenterUIKit at runtime on roothide and use the private
# framework only on the rootless lane.
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NetworkManager_PRIVATE_FRAMEWORKS = ControlCenterUIKit
else
NetworkManager_LIBRARIES = roothide
NetworkManager_LDFLAGS += -undefined dynamic_lookup
endif

after-install::
	install.exec "killall -9 SpringBoard"

include $(THEOS_MAKE_PATH)/bundle.mk
SUBPROJECTS += networkmanagerprefs
SUBPROJECTS += maintenance-daemon
SUBPROJECTS += package-actions
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/scripts/patch-maintenance-launchd.py" \
		--scheme "$(THEOS_PACKAGE_SCHEME)" \
		--staging-dir "$(THEOS_STAGING_DIR)"$(ECHO_END)
