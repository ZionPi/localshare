# 2026-07-21 LocalShare 稳定性与当前访问地址改造记录

## 背景

本轮集中处理 LocalShare 使用中的严重问题，重点是：手机作为局域网 Web 服务器时，电脑端需要看到“当前应该访问哪个网址”。理想情况下，这个地址应优先使用相对稳定的 mDNS/Bonjour 主机名，例如 `android_pddwcd2v.local`，从而避免手机 IP 在家庭、公司等不同 Wi-Fi 环境中变化后需要重新输入；如果当前网络或系统无法确认 `.local` 主机名，则 IP 地址只能作为当前可访问的 fallback。

## 已完成的代码改动

### 1. 手机端卡片批量管理

- 手机端卡片列表增加多选能力。
- 支持当前列表全选、取消选择、批量删除。
- 设置页新增“卡片管理”下一级页面。
- 卡片管理页支持：
  - 搜索正文或附件名；
  - 按今天、最近 7 天、最近 30 天筛选；
  - 按置顶、包含附件、包含图片、仅文本筛选；
  - 选中筛选结果并批量删除。

### 2. 网页端卡片批量管理与折叠

- Web 页面增加批量工具条：
  - 全选当前列表；
  - 取消选择；
  - 删除选中；
  - 全部折叠；
  - 全部展开。
- 单张卡片增加选择框和折叠/展开按钮。
- 修复网页端粘贴图片重复触发的问题：去掉重复的全局 paste 监听，仅保留输入框 paste 处理。

### 3. 手机端启停交互

- 顶部服务控制从横向滑动启停改为明确按钮：
  - 启动服务；
  - 停止服务；
  - 复制地址。
- 无局域网地址时不再显示 `127.0.0.1` 作为可访问地址，而是显示不可用状态。

### 4. 当前访问地址与 mDNS 主机名

- Android 端继续使用 NSD/mDNS 注册 `_http._tcp.local` 服务。
- 服务实例名固定为 `localshare`，便于在 Windows/macOS 上通过 Bonjour/mDNS 工具发现。
- 手机端顶部应显示“当前访问地址”，不是“推荐收藏地址”或“局域网收藏地址”。
- 当前访问地址的优先级应是：
  1. 已确认可用的 `.local` 主机名地址，例如电脑通过 DNS-SD 解析到的 `android_pddwcd2v.local`；
  2. Android NSD 返回的 `bookmarkUrl`，前提是该 hostname 在当前电脑端确实可解析；
  3. 当前 Wi-Fi 下的 IP 地址，例如 `http://192.168.31.142:35773`，仅作为 fallback。
- 如果 Android 回调拿不到 hostname，不能把某一次实测的 `Android.local` 当成通用地址。不同设备、厂商系统、网络环境下，实际主机名可能不同，例如：

```text
http://android_pddwcd2v.local:35773
```

> 注意：`.local` 主机名是“相对稳定的当前访问地址”，不是永久不变的承诺。后续应支持在设置页手动配置当前环境中确认可用的主机名；没有可用 `.local` 时，手机端必须仍能显示当前 IP 地址作为 fallback。

### 5. 手机端下载网页上传文件

- 手机端下载本机已保存附件时，优先直接复制本地文件到 Android Downloads，而不是通过 HTTP 回环下载。
- 多附件打包下载时，优先在本地生成临时 zip 后保存到 Downloads。
- 目的是减少 DownloadManager 访问本机 Web 服务失败导致“网页上传后手机端难以下载”的问题。

### 6. 导出全部卡片

- 导出全部卡片增加停止入口。
- zip 构建改为流式写入文件，避免把所有附件一次性读入内存导致 OOM。
- 取消导出通过临时取消标记文件通知 isolate 停止。

### 7. 临时对话模式

新增 Web 端“临时对话”区域：

- 微信式聊天气泡风格。
- 支持临时发送文字和文件。
- 最近临时会话保存到本地临时状态文件，但不会自动生成卡片。
- 每条聊天气泡支持：
  - 存为卡片；
  - 复制；
  - 删除。
- 支持清空全部临时对话。
- 临时附件保存到独立目录 `temp_chat_attachments/`。

## Windows 端 `.local` 验证记录

### 问题现象

最初访问：

```text
http://localshare.local:35773
```

失败。PowerShell 测试：

```powershell
curl.exe -v --noproxy "*" http://localshare.local:35773
```

返回：

```text
Could not resolve host: localshare.local
```

说明不是 Clash 规则问题，而是 Windows 当时不能解析该 `.local` 名称。

### Bonjour/mDNS 工具验证

安装/启用 Bonjour 后，PowerShell 可运行：

```powershell
dns-sd -B _http._tcp local
```

发现 LocalShare 服务：

```text
localshare
```

进一步查询：

```powershell
dns-sd -L localshare _http._tcp local
```

返回：

```text
localshare._http._tcp.local. can be reached at Android.local.:35773
```

最终实测可访问：

```text
http://android.local:35773/
```

### 结论

- `localshare` 是 mDNS 服务实例名，不等于浏览器可直接访问的 hostname。
- `Android.local` 只是当时 Windows 环境解析到的主机名，不是通用值。
- macOS 上同一台手机可能解析为 `Android_PDDWCD2V.local`，浏览器实际可访问地址应以 DNS-SD 查询结果或真实请求 Host 为准。
- 当前访问地址应优先显示实际 `.local` 主机名地址，例如：

```text
http://android_pddwcd2v.local:35773
```

- 如果 `.local` 当前不可解析，则退回显示当前 Wi-Fi IP 地址，保证用户仍然知道手机服务器怎么访问。

## 关于不同机器无法覆盖安装 APK 的原因

本轮在另一台已安装 LocalShare 的手机上尝试覆盖安装新版 APK 时失败：

```text
INSTALL_FAILED_UPDATE_INCOMPATIBLE:
Existing package com.lix.localshare signatures do not match newer version
```

原因：Android 覆盖安装要求新旧 APK 使用同一签名私钥。当前仓库没有旧版 release 签名材料：

- `android/key.properties`
- 对应 `.jks` / `.keystore`
- store password / key password

当前仓库的 release 构建使用 debug 签名：

```gradle
signingConfig = signingConfigs.debug
```

因此：

- 如果目标设备上已有用另一套私钥签名的旧版 App，则无法保留数据覆盖安装。
- 仅能看到已安装 APK 的证书指纹，不能从证书指纹反推出私钥。
- 若找不到旧 keystore，则只能：
  1. 在旧 App 中先导出备份；
  2. 卸载旧 App；
  3. 安装新版；
  4. 再导入备份。

这也是“换一台未安装旧签名版本的设备可以安装成功，而原设备不能覆盖安装”的根本原因。

## 本轮实际安装记录

- 新版 APK 已成功构建：

```text
build/app/outputs/flutter-apk/app-release.apk
```

- 已复制到 Windows：

```text
C:\Users\Administrator\Downloads\localshare-release.apk
```

- 已成功安装到 HONOR Pad 7：

```text
AE5HNU1604404926  AGM3_AL09HN
```

## 已验证

- `flutter analyze`：通过。
- `flutter test`：通过。
- Release APK 构建：通过。
- HONOR Pad 7 覆盖安装：通过。
- Windows 端 Bonjour 能发现 `localshare` 服务。
- Windows 浏览器可访问 `http://android.local:35773/`。

## 仍需后续验证或优化

1. `Android.local` 不是通用 fallback。建议后续在设置页增加“当前主机名 / .local 地址”手动配置，并允许从电脑端真实访问 Host 自动学习。
2. 后台保活仍需长时间真机验证，尤其是锁屏、省电策略、退后台后的 WebSocket 连接状态。
3. 手机端下载网页上传文件已改为本地复制优先，但仍需多类型文件实测。
4. 临时对话模式已完成主体功能，但还需浏览器/手机双端连续互传压力测试。
5. 如果未来需要无损升级所有设备，必须建立并备份正式 release keystore，不要依赖 debug 签名。
