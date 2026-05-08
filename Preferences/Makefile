ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VolumeChordRecorderPrefs
VolumeChordRecorderPrefs_FILES = VCRRootListController.mm
VolumeChordRecorderPrefs_FRAMEWORKS = UIKit
VolumeChordRecorderPrefs_PRIVATE_FRAMEWORKS = Preferences
VolumeChordRecorderPrefs_INSTALL_PATH = /Library/PreferenceBundles
VolumeChordRecorderPrefs_RESOURCE_FILES = Info.plist
VolumeChordRecorderPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
