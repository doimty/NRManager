ifndef THEOS
$(error THEOS is not set)
endif

TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NetworkManagerLive

NetworkManagerLive_BUNDLE_EXTENSION = bundle
NetworkManagerLive_FILES = \
	Sources/NetworkManagerLiveModule.m \
	Sources/CCNMLiveBandText.c \
	Sources/CCNMLiveServingPaths.m \
	../networkmanagerprefs/CCNMServingStatusProvider.m \
	../networkmanagerprefs/CCNMServingCellSampler.m
NetworkManagerLive_INSTALL_PATH = /Library/ControlCenter/Bundles
NetworkManagerLive_RESOURCE_DIRS = Resources
NetworkManagerLive_CFLAGS = -fobjc-arc -Iinclude -I../networkmanagerprefs
NetworkManagerLive_CFLAGS += -DCCNMServingStatusProvider=CCNMLiveServingStatusProvider
NetworkManagerLive_CFLAGS += -Wno-error=objc-method-access
NetworkManagerLive_FRAMEWORKS = CoreFoundation CoreTelephony Foundation QuartzCore UIKit
NetworkManagerLive_PRIVATE_FRAMEWORKS = ControlCenterUIKit

include $(THEOS_MAKE_PATH)/bundle.mk
