APP_ID := com.lix.localshare
FLUTTER ?= flutter
ADB ?= adb
DEVICE ?=
ADB_TARGET := $(if $(DEVICE),-s $(DEVICE),)
DEBUG_APK := build/app/outputs/flutter-apk/app-debug.apk
RELEASE_APK := build/app/outputs/flutter-apk/app-release.apk

.PHONY: help deps devices doctor apk release-apk install install-release install-apk install-release-apk run restart logs uninstall clean

help:
	@printf '%s\n' \
		'make deps            - 拉取 Flutter 依赖' \
		'make devices         - 查看已连接设备' \
		'make doctor          - 查看 Flutter 环境' \
		'make apk             - 构建 debug APK' \
		'make release-apk     - 构建 release APK' \
		'make install         - 安装 debug 包到已连接手机' \
		'make install-release - 安装 release 包到已连接手机' \
		'make install-apk     - 安装本地 debug APK 到手机' \
		'make install-release-apk - 安装本地 release APK 到手机' \
		'make run             - 直接在已连接手机上启动调试' \
		'make restart         - 重启手机上的应用' \
		'make logs            - 查看该应用日志' \
		'make uninstall       - 从已连接手机卸载应用' \
		'make clean           - 清理构建产物' \
		'' \
		'可选参数:' \
		'  DEVICE=<serial>    - 指定某一台 Android 设备'

deps:
	$(FLUTTER) pub get

devices:
	$(ADB) devices -l

doctor:
	$(FLUTTER) doctor -v

apk:
	$(FLUTTER) build apk --debug

release-apk:
	$(FLUTTER) build apk --release

install: apk
	$(ADB) $(ADB_TARGET) install -r $(DEBUG_APK)

install-release: release-apk
	$(ADB) $(ADB_TARGET) install -r $(RELEASE_APK)

install-apk: install

install-release-apk: install-release

run:
	$(FLUTTER) run $(if $(DEVICE),-d $(DEVICE),)

restart:
	$(ADB) $(ADB_TARGET) shell am force-stop $(APP_ID)
	$(ADB) $(ADB_TARGET) shell monkey -p $(APP_ID) -c android.intent.category.LAUNCHER 1

logs:
	$(ADB) $(ADB_TARGET) logcat --pid="$$( $(ADB) $(ADB_TARGET) shell pidof -s $(APP_ID) )"

uninstall:
	$(ADB) $(ADB_TARGET) uninstall $(APP_ID)

clean:
	$(FLUTTER) clean
