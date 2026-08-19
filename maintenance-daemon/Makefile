include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

TOOL_NAME = networkmanager-maintenance

networkmanager-maintenance_FILES = main.m \
	../networkmanagerprefs/CCNMN78PolicySupport.m \
	../networkmanagerprefs/CCNMN78PolicyReader.m \
	../networkmanagerprefs/CCNMServingStatusProvider.m \
	../networkmanagerprefs/CCNMServingCellSampler.m \
	../networkmanagerprefs/CCNMAutomaticMaintenanceDecision.c \
	../networkmanagerprefs/CCNMAutomaticMaintenanceRecord.m
networkmanager-maintenance_FRAMEWORKS = CoreTelephony Foundation
networkmanager-maintenance_CFLAGS = -fobjc-arc
networkmanager-maintenance_INSTALL_PATH = /usr/libexec

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
networkmanager-maintenance_LIBRARIES = roothide
networkmanager-maintenance_LDFLAGS += -undefined dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tool.mk