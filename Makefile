# roothide / rootless (ElleKit) iOS 16 适配
ARCHS = arm64
TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

# roothide 打包方案：标准 Theos 用 rootless；若使用 roothide/Theos 分支可改为 roothide
THEOS_PACKAGE_SCHEME = rootless
# macOS 无 lzma，deb 用 gzip 压缩（iOS 端 dpkg/Sileo 兼容）
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

THEOS_DEVICE_IP = 192.168.1.5


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TTtest

TTtest_FILES = Tweak.x
# 用最新 SDK 编译旧代码：关闭 deprecated 警告，并把警告降级不当作错误
# （keyWindow / AVCaptureStillImageOutput / openURL: 等 API 在 iOS16 上仍可用）
TTtest_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-error -Wno-unused-but-set-variable
# 链接 ElleKit 提供的 substrate 兼容库（roothide 注入基于 ElleKit）
TTtest_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
