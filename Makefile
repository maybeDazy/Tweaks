ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0   # pinned: CI used iPhoneOS16.5.sdk; matches the documented 15.0 floor

# Build with:
#   make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
#   make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeChordRecorder
VolumeChordRecorder_FILES = Tweak.xm VCRTelegramUploader.m
VolumeChordRecorder_CFLAGS = -fobjc-arc
VolumeChordRecorder_FRAMEWORKS = UIKit AVFoundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
