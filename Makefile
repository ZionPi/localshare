APP_ID := com.lix.localshare
FLUTTER ?= flutter
ADB ?= adb
DEVICE ?=
SELECTED_DEVICE := $(shell $(ADB) devices | awk '\
	NR > 1 && $$2 == "device" { \
		if ($$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$$/ && ip == "") { ip = $$1 } \
	} \
	END { \
		if (ip != "") print ip; \
	}')
RESOLVED_DEVICE := $(if $(DEVICE),$(DEVICE),$(SELECTED_DEVICE))
ADB_TARGET := $(if $(RESOLVED_DEVICE),-s $(RESOLVED_DEVICE),)
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
		'  DEVICE=<serial>    - 指定某一台 Android 设备' \
		'' \
		'默认设备选择:' \
		'  1. 只使用无线 IP:端口设备' \
		'  2. 不使用 _adb-tls-connect._tcp 别名设备' \
		'  3. 找不到无线 IP:端口设备时直接报错'

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
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可安装的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(ADB) $(ADB_TARGET) install -r $(DEBUG_APK)

install-release: release-apk
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可安装的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(ADB) $(ADB_TARGET) install -r $(RELEASE_APK)

install-apk: install

install-release-apk: install-release

run:
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可运行的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(FLUTTER) run -d $(RESOLVED_DEVICE)

restart:
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可重启的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(ADB) $(ADB_TARGET) shell am force-stop $(APP_ID)
	$(ADB) $(ADB_TARGET) shell monkey -p $(APP_ID) -c android.intent.category.LAUNCHER 1

logs:
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可查看日志的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(ADB) $(ADB_TARGET) logcat --pid="$$( $(ADB) $(ADB_TARGET) shell pidof -s $(APP_ID) )"

uninstall:
	@test -n "$(RESOLVED_DEVICE)" || (echo "未找到可卸载的 Android 设备" && exit 1)
	@echo "Using device: $(RESOLVED_DEVICE)"
	$(ADB) $(ADB_TARGET) uninstall $(APP_ID)

clean:
	$(FLUTTER) clean
