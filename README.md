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

### 白板

手机 App 的「设置」→「白板模式」切换手机和 Web 的共享模式。Web 首页随 App 自动切换，不增加独立白板入口。两端都可绘图，手机白板内支持切换横屏。两端使用同一份画布，内容自动保存到手机，并为每块画布维护一张显示最新画面、带有「白板」及画布名称 chip 的图片卡片。手机没有 Wi-Fi 时也能通过应用内白板编辑。

顶部可直接导出 PNG 或 `.excalidraw` 源文件；源文件可通过白板菜单重新打开。退出手机白板前会检查是否保存完成。

App 白板内可以新建、选择和重命名画布；Web 跟随 App 选择的画布，两端都能编辑。切换前会等待当前画布保存成功，失败时保留当前画布。每块画布独立保存，不提供多人同时编辑时的自动合并。多个页面同时编辑时，旧页面的保存会被拒绝，并提示先导出备份再重新载入，避免覆盖其他页面的修改。保存失败会显示状态并自动重试。白板及嵌入图片的请求大小上限为 32 MB，原有画布保留在 `whiteboard_v1.json`，作为「画布 1」；列表及新增画布保存于应用数据目录的 `whiteboards/`，升级不会移动或删除原画布。卡片导出包含预览图片，编辑用的完整画布请从白板另行导出 `.excalidraw`。

下载附件会保留应用内原件，独立记录下载副本。重复点击会提示文件已存在，删除下载副本后可以重新下载。旧版曾移动到下载目录的附件在文件仍存在时会自动保留一份原件；已删除且没有原件的旧文件需要重新上传。

编辑器脚本、样式和字体都随 APK 打包，绘图无需外网。修改 `whiteboard/` 源码后运行：

```sh
make whiteboard       # 安装锁定依赖，构建 assets/whiteboard.zip
make release-apk     # 使用本机已有的 release 配置构建 APK
```

APK 使用已打包的 `assets/whiteboard.zip`；仅构建 Flutter 时不需要 Node.js。
