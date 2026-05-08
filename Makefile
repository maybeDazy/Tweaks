ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

# Build with:
#   make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
#   make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeChordRecorder
VolumeChordRecorder_FILES = Tweak.xm
VolumeChordRecorder_CFLAGS = -fobjc-arc
VolumeChordRecorder_FRAMEWORKS = UIKit AVFoundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
