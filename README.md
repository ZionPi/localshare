# localshare

局域网本地分享工具，支持把文本和附件保存为卡片，并通过手机/电脑在同一局域网内访问。

## 当前实现

- 全新 Flutter 首页与 Web 页面，统一视觉风格
- 服务地址支持随机端口，不再固定 `8080`
- 卡片与附件改为本地文件持久化，并带旧数据迁移/备份
- Web 端复制提示改为非阻塞轻提示，不再使用 `alert`
- 附件下载/预览链路已调整，改善手机端下载体验
- Android 分享到 LocalShare 后，保存成功会自动关闭分享唤起页

## 局域网 API

手机连接 Wi-Fi 并启动服务后，在 App 的「设置 → 局域网 API」查看当前地址。使用同一局域网内的设备访问：

接口列表网页：`http://手机IP:端口/api/docs`。

```bash
curl 'http://手机IP:端口/api/v1/cards'
```

返回 JSON 对象，其中 `cards` 包含普通卡片和归档卡片。卡片含 `id`、`text`、`createdAt`、`updatedAt`、`pinned`、`archived`、`source` 和 `attachments` 等字段。附件的 `downloadUrl` 和 `previewUrl` 是相对路径，需拼接服务地址。返回结果不包含临时聊天记录或手机内部文件路径。

卡片接口：

| 方法 | 路径 | 功能 |
| --- | --- | --- |
| GET | `/api/v1/cards?q=关键词&archived=false` | 列表、搜索和归档筛选（参数均可省略） |
| GET | `/api/v1/cards/{id}` | 卡片详情 |
| POST | `/api/v1/cards` | JSON 创建文本卡片，例如 `{"text":"你好"}` |
| PATCH | `/api/v1/cards/{id}` | JSON 更新 `text`、`pinned`、`archived` |
| DELETE | `/api/v1/cards/{id}` | 删除卡片和应用内附件 |
| POST | `/api/v1/cards/upload` | multipart 创建带附件的卡片 |
| GET | `/files/{attachmentId}` | 下载附件，`?view=1` 预览 |
| GET | `/cards/{cardId}/bundle` | 下载卡片的全部附件 ZIP |

上传接口要求 multipart 第一部分是 `metadata` JSON，含 `text` 和 `attachments` 数组；每个附件写明 `name`、`mimeType`、`size`（字节数），后面按相同顺序发送名为 `file` 的文件部分。具体示例和临时聊天接口见 App 的 API 页面。

接口无需认证，能够访问服务的局域网设备可读取和修改卡片，也可删除内容。服务必须保持运行；如果需要稳定端口，可在设置中开启固定端口。

## 数据存储

应用会把数据保存到本地应用目录：

- 卡片元数据：`cards_state_v2.json`
- 附件文件：`attachments/`
- 迁移/自动备份：`backups/`

目标是保证在开发重构、热重载、热重启、普通重启后，历史卡片和附件尽量不丢失。

## 构建

项目提供 `Makefile`。构建 release 包必须走 Makefile，让它读取本机私有配置 `localshare.local.mk`：

```bash
make release-apk
```

不要直接运行裸命令：

```bash
flutter build apk --release
```

裸命令不会注入 `WECHAT_ARTICLE_API_BASE_URL`，手机端复制支持的链接后会无法自动抓取正文。

输出文件：

```bash
build/app/outputs/flutter-apk/app-release.apk
```

## 安装说明

如果只是安装本地已经构建好的 release APK，可直接：

```bash
make install-release-apk
```

如果设备上已经安装了旧版本并且要保留数据，需要保证**签名一致**后再覆盖安装：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

其中：

- `make release-apk`：只构建 release APK，并检查 `WECHAT_ARTICLE_API_BASE_URL`
- `make install-release`：先构建，再覆盖安装 release APK
- `make install-release-apk`：直接安装本地现成的 release APK，不会重新编译

## 签名注意事项

当前仓库**不包含私有 release 签名文件**。如果旧设备上已经安装的是用另一套签名打包的版本，直接覆盖安装会报：

`INSTALL_FAILED_UPDATE_INCOMPATIBLE`

这时需要从原始构建环境同步：

- `android/key.properties`
- 对应的 `.jks` / `.keystore`

然后使用同一套签名重新构建，才能在**不卸载、不丢数据**的前提下升级安装。
