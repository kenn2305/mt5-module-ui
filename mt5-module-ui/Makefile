export THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = MetaTrader5Terminal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MT5ModuleUI

MT5ModuleUI_FILES = \
	Tweak.xm \
	Sources/MUIModule.m \
	Sources/MUIConfigStore.m \
	Sources/MUIRuntime.m \
	Sources/MUIPreviewView.m \
	Sources/MUIDesignerViewController.m

MT5ModuleUI_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
MT5ModuleUI_FRAMEWORKS = UIKit Foundation PhotosUI UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 MetaTrader5Terminal || true"
