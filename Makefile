include $(THEOS)/makefiles/common.mk

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

# The formal package intentionally has no Control Center bundle. The standalone
# LiveCC package owns the read-only serving preview; this package owns Settings,
# policy recovery, and automatic maintenance only. Keep the old source files in
# the repository for the standalone build and historical tests, but do not ship
# the duplicate NetworkManager.bundle from this package.
SUBPROJECTS += networkmanagerprefs
SUBPROJECTS += maintenance-daemon
SUBPROJECTS += package-actions
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/scripts/patch-maintenance-launchd.py" \
		--scheme "$(THEOS_PACKAGE_SCHEME)" \
		--staging-dir "$(THEOS_STAGING_DIR)"$(ECHO_END)
