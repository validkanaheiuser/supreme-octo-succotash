THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TouchGeoFix

TouchGeoFix_FILES = Tweak.x
TouchGeoFix_CFLAGS = -fobjc-arc -Wno-unused-variable
TouchGeoFix_LDFLAGS = -lsubstrate
TouchGeoFix_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/tweak.mk
