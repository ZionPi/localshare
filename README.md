# localshare

局域网本地分享工具，支持把文本和附件保存为卡片，并通过手机/电脑在同一局域网内访问。

## 当前实现

- 全新 Flutter 首页与 Web 页面，统一视觉风格
- 服务地址支持随机端口，不再固定 `8080`
- 卡片与附件改为本地文件持久化，并带旧数据迁移/备份
- Web 端复制提示改为非阻塞轻提示，不再使用 `alert`
- 附件下载/预览链路已调整，改善手机端下载体验
- Android 分享到 LocalShare 后，保存成功会自动关闭分享唤起页

## 数据存储

应用会把数据保存到本地应用目录：

- 卡片元数据：`cards_state_v2.json`
- 附件文件：`attachments/`
- 迁移/自动备份：`backups/`

目标是保证在开发重构、热重载、热重启、普通重启后，历史卡片和附件尽量不丢失。

## 构建

项目提供 `Makefile`：

```bash
make release-apk
```

输出文件：

```bash
build/app/outputs/flutter-apk/app-release.apk
```

## 安装说明

如果只是安装到新设备，可直接：

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

如果设备上已经安装了旧版本并且要保留数据，需要保证**签名一致**后再覆盖安装：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## 签名注意事项

当前仓库**不包含私有 release 签名文件**。如果旧设备上已经安装的是用另一套签名打包的版本，直接覆盖安装会报：

`INSTALL_FAILED_UPDATE_INCOMPATIBLE`

这时需要从原始构建环境同步：

- `android/key.properties`
- 对应的 `.jks` / `.keystore`

然后使用同一套签名重新构建，才能在**不卸载、不丢数据**的前提下升级安装。
