ifndef THEOS
$(error THEOS is not set)
endif

TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NRManagerLive

NRManagerLive_BUNDLE_EXTENSION = bundle
NRManagerLive_FILES = \
	Sources/NRManagerLiveModule.m \
	Sources/CCNMLiveBandText.c \
	Sources/CCNMLiveServingPaths.m \
	../nrmanagerprefs/CCNMServingStatusProvider.m \
	../nrmanagerprefs/CCNMServingCellSampler.m
NRManagerLive_INSTALL_PATH = /Library/ControlCenter/Bundles
NRManagerLive_RESOURCE_DIRS = Resources
NRManagerLive_CFLAGS = -fobjc-arc -Iinclude -I../nrmanagerprefs
NRManagerLive_CFLAGS += -DCCNMServingStatusProvider=CCNMLiveServingStatusProvider
NRManagerLive_CFLAGS += -DCCNMCellMonitorAsyncState=CCNMLiveCellMonitorAsyncState
NRManagerLive_CFLAGS += -DCCNM_SERVING_USE_LIVECC_NAMESPACE=1
NRManagerLive_CFLAGS += -Wno-error=objc-method-access
NRManagerLive_FRAMEWORKS = CoreFoundation CoreTelephony Foundation QuartzCore UIKit
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
NRManagerLive_PRIVATE_FRAMEWORKS = ControlCenterUIKit
else
NRManagerLive_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/bundle.mk
