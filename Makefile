include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

BUNDLE_NAME = NRManager
NRManager_BUNDLE_EXTENSION = bundle
NRManager_FILES = CCNRManager.x \
	livecc/Sources/CCNMLiveBandText.c \
	livecc/Sources/CCNMLiveServingPaths.m \
	nrmanagerprefs/CCNMServingStatusProvider.m \
	nrmanagerprefs/CCNMServingCellSampler.m \
	nrmanagerprefs/CCNMAutomaticMaintenanceDecision.c
NRManager_FRAMEWORKS = CoreFoundation CoreTelephony Foundation UIKit
NRManager_INSTALL_PATH = /Library/ControlCenter/Bundles

NRManager_CFLAGS += -fobjc-arc
NRManager_CFLAGS += "-Wno-error=objc-method-access"
NRManager_CFLAGS += -Ilivecc/include -Inrmanagerprefs
NRManager_CFLAGS += -DCCNMServingStatusProvider=CCNMLiveServingStatusProvider
NRManager_CFLAGS += -DCCNMCellMonitorAsyncState=CCNMLiveCellMonitorAsyncState
NRManager_CFLAGS += -DCCNM_SERVING_USE_LIVECC_NAMESPACE=1
NRManager_CFLAGS += -DCCNM_LIVE_MAIN_BUNDLE=1
NRManager_CFLAGS += -DNRManagerLiveViewController=CCNRManagerViewController
NRManager_CFLAGS += -DNRManagerLiveModule=CCNRManager

# Resolve ControlCenterUIKit at runtime on roothide and use the private
# framework only on the rootless lane.
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NRManager_PRIVATE_FRAMEWORKS = ControlCenterUIKit
else
NRManager_LIBRARIES = roothide
NRManager_LDFLAGS += -undefined dynamic_lookup
endif

after-install::
	install.exec "killall -9 SpringBoard"

include $(THEOS_MAKE_PATH)/bundle.mk
SUBPROJECTS += nrmanagerprefs
SUBPROJECTS += maintenance-daemon
SUBPROJECTS += package-actions
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/scripts/patch-maintenance-launchd.py" \
		--scheme "$(THEOS_PACKAGE_SCHEME)" \
		--staging-dir "$(THEOS_STAGING_DIR)"$(ECHO_END)
