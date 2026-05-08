# VolumeChordRecorder - Theos tweak project
# Windows build path: WSL2 Ubuntu + Theos
# Supported package schemes:
#   rootless: make clean package THEOS_PACKAGE_SCHEME=rootless
#   roothide: make clean package THEOS_PACKAGE_SCHEME=roothide

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

# Default to rootless. Override on command line for RootHide:
# make package THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeChordRecorder
VolumeChordRecorder_FILES = Tweak.xm
VolumeChordRecorder_CFLAGS = -fobjc-arc
VolumeChordRecorder_FRAMEWORKS = Foundation AVFoundation AudioToolbox UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
