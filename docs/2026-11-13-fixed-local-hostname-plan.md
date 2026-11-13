# 固定 `.local` 访问地址实施方案

日期：2026-11-13
状态：待实施（本文只是方案，代码尚未改动）

## 目标

手机每次连上 Wi-Fi 后 IP 都可能变化，但电脑端始终用同一个网址访问 LocalShare：

```text
http://localshare.local:35773
```

约束：

- 不手动设置静态 IP，不改路由器配置。
- 电脑端只需浏览器，不需要安装额外软件（Windows 10+/macOS/Linux 自带 mDNS 解析）。
- 当前网络解析不了 `.local` 时，仍然显示当前 IP 地址作为后备。

## 现状与问题

现有实现（见 `docs/2026-07-21-localshare-stability-and-lan-bookmark.md`）：

- `MainActivity.kt` 用 `NsdManager` 注册 `_http._tcp` 服务，实例名为 `localshare`，端口默认 `35773`（`lib/main.dart` 的 `_defaultServerPort`）。
- `LocalShareForegroundService.kt` 持有 MulticastLock。
- `lib/main.dart` 的 `_recordObservedRequestAddress` 会从请求的 Host 头里学习 `.local` 地址。

问题：

1. **`localshare` 只是 DNS-SD 服务实例名，不是主机名。** 浏览器访问 `localshare.local` 解析的是 A 记录，NSD 不会发布这条记录，所以 Windows 实测 `Could not resolve host: localshare.local`。
2. **主机名由 Android 系统决定，App 无法通过 NSD 修改。** 同一台设备在 Windows 上解析为 `Android.local`，在 macOS 上解析为 `Android_PDDWCD2V.local`，不同厂商和系统版本也不一样。
3. Dart 侧 `_syncDiscoveryService` 拿到 `bookmarkUrl` 后，无论结果如何都把 `_bookmarkAddress` 设为 `null`，NSD 返回的 hostname 实际上没有被使用。
4. `buildDiscoveryServiceName()` 计算了 ANDROID_ID 后缀，但直接返回常量 `DISCOVERY_SERVICE_NAME`，`suffix` 和 `sanitizeServiceName` 都没有用上。
5. 注册逻辑在 `MainActivity`，`onDestroy` 会注销服务。mDNS 广播的生命周期绑在 Activity 上，而不是前台服务上。注意 HTTP 服务器跑在 Dart 里，由 Activity 持有的 FlutterEngine 承载，所以 Activity 被回收时 HTTP 服务也会一起停。这是另一个问题（后台保活），本方案只保证广播不比 HTTP 服务先消失。
6. 没有监听网络变化。切换 Wi-Fi 后不会用新 IP 重新广播。

## 方案：App 自己做 mDNS 应答（JmDNS）

用 JmDNS 在 App 里运行一个 mDNS 应答器，由它自己回答 `localshare.local` 的 A 记录查询，并发布 `_http._tcp` 服务（SRV 记录的目标指向 `localshare.local`）。这样主机名完全由 App 决定。

为什么选 JmDNS：

- Android 原生 `NsdManager` 不能自定义主机名（问题 2）。
- Dart 的 `multicast_dns` 包只能查询，不能应答。
- JmDNS 是成熟的 Java 实现，兼容 Bonjour，`JmDNS.create(address, name)` 的 `name` 就是对外应答的主机名。

### 1. 依赖

`android/app/build.gradle` 的 `dependencies` 中加入（版本以 Maven Central 最新 3.6.x 为准，调研时看到 3.6.4）：

```groovy
implementation "org.jmdns:jmdns:3.6.4"
```

release 构建已开启 `minifyEnabled true`，并引用了 `proguard-rules.pro`，但 `android/app/proguard-rules.pro` 目前不存在。需要新建该文件并加入：

```proguard
-keep class javax.jmdns.** { *; }
-dontwarn javax.jmdns.**
```

然后用 release 包真机验证。

### 2. 新建 `LocalHostnameAdvertiser.kt`

放在 `android/app/src/main/kotlin/com/lix/localshare/`，职责单一：

```kotlin
class LocalHostnameAdvertiser(private val context: Context) {
    private var jmdns: JmDNS? = null
    private val executor = Executors.newSingleThreadExecutor() // JmDNS 有阻塞调用，不能在主线程

    /** 用当前 Wi-Fi IPv4 启动或重启广播，返回实际生效的主机名（可能因冲突被改名）。 */
    fun start(hostname: String, port: Int, address: InetAddress, onReady: (String) -> Unit) {
        executor.execute {
            stopInternal()
            val instance = JmDNS.create(address, hostname)          // 应答 hostname.local 的 A 记录
            val info = ServiceInfo.create("_http._tcp.local.", "localshare", port, "path=/")
            instance.registerService(info)
            jmdns = instance
            onReady(instance.hostName.removeSuffix(".").removeSuffix(".local"))
        }
    }

    fun stop() = executor.execute { stopInternal() }

    private fun stopInternal() {
        jmdns?.run { unregisterAllServices(); close() }
        jmdns = null
    }
}
```

要点：

- `address` 必须是当前 Wi-Fi 接口的 IPv4，不能用 `0.0.0.0` 或移动数据接口的地址。
- 名字冲突时 JmDNS 会自动改名（例如 `localshare-2`），必须读回 `instance.hostName`，界面显示真实生效的名字。
- `onReady` 回调在后台线程，回到 Flutter 前需要切到主线程。

### 3. 移到前台服务里管理

把 mDNS 广播的生命周期从 `MainActivity` 移到 `LocalShareForegroundService`：

- 前台服务已经持有 MulticastLock，广播和锁的生命周期保持一致。
- 服务 `onCreate`/启动 HTTP 后调用 `advertiser.start(...)`，`onDestroy` 调用 `advertiser.stop()`。
- 删除 `MainActivity.onDestroy` 中的注销，避免 Activity 回收时广播消失。
- `MainActivity` 中的 `registerHttpService` / `getRegisteredHttpService` / `unregisterHttpService` 通道保留，改为转发到服务（或通过共享单例访问 advertiser），Dart 侧调用方式尽量不变。

### 4. 停用 NSD 注册

JmDNS 接管后，删除 `NsdManager` 的注册代码（`registerHttpDiscoveryService`、`applyAdvertisedAddress`、`extractAdvertisedHostname` 等）以及未使用的 `buildDiscoveryServiceName` 后缀逻辑和 `sanitizeServiceName`（或复用它来清洗主机名）。

原因：NSD 和 JmDNS 同时发布名为 `localshare` 的 `_http._tcp` 实例会互相冲突，其中一个会被改名。

### 5. 监听网络变化

在前台服务中注册 `ConnectivityManager.NetworkCallback`（使用 `NetworkRequest` 过滤 `TRANSPORT_WIFI`）：

- `onLinkPropertiesChanged`：取出新的 IPv4，如果和当前广播的地址不同，就用新地址调用 `advertiser.start(...)` 重新广播。
- `onLost`：调用 `advertiser.stop()`。
- 重新广播后通知 Flutter，刷新界面上的地址。

`ACCESS_NETWORK_STATE`、`ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE` 权限已经在 `AndroidManifest.xml` 里，不需要新增权限。

### 6. 可配置主机名

- 设置页增加一个“主机名”输入项，默认 `localshare`，用 `SharedPreferences` 保存（参照 `_preferredPortKey` 的写法）。
- 只允许 `[a-z0-9-]`，长度不超过 63，首尾不能是 `-`。可以复用 `sanitizeServiceName` 的规则。
- 修改后立即重新广播。

同一个局域网里有两台手机都装了 LocalShare 时，第二台会被改名为 `localshare-2`。用户可以给每台设备设不同的名字，比如 `pad.local`、`phone.local`。

### 7. Dart 侧地址显示

`lib/main.dart`：

- `_syncDiscoveryService` 不要再把 `_bookmarkAddress` 无条件置空。使用原生返回的实际主机名拼出 `http://<hostname>.local:<port>`。
- 地址显示优先级：
  1. 电脑实际访问时 Host 头里的 `.local` 地址（`_recordObservedRequestAddress`，已有）；
  2. JmDNS 实际生效的主机名地址；
  3. 当前 Wi-Fi IP 地址（后备，必须一直能看到）。
- 建议两个地址同时显示：`.local` 地址作为主地址，IP 作为“如果打不开就用这个”。
- 端口必须固定，否则网址仍会变化。启动时如果 `35773` 被占用，应提示用户，而不是悄悄换成随机端口。

## 已知限制（写进 README 或界面说明）

- 只在同一个网段内有效。公司或公共 Wi-Fi 如果开启了 AP 隔离或屏蔽组播，`.local` 无法解析，只能用 IP。
- Android 手机/平板作为访问端时，浏览器解析 `.local` 不稳定，主要面向电脑端访问。
- Windows 上要确认浏览器没有走代理（Clash 等）解析 `.local`，可以把 `*.local` 加入直连或代理绕过。
- iOS 版本如果要做同样的事，需要 `NSLocalNetworkUsageDescription`、`NSBonjourServices`，并且自定义 A 记录需要 multicast 网络权限（`com.apple.developer.networking.multicast` entitlement），不在本方案范围内。

## 验证清单

1. 真机启动服务后，Windows 执行 `ping localshare.local` 能解析到手机当前 IP。
2. Windows / macOS 浏览器打开 `http://localshare.local:35773` 正常。
3. `dns-sd -L localshare _http._tcp local`（或 `scripts/discover_localshare.py`）显示目标为 `localshare.local.:35773`。
4. 切换到另一个 Wi-Fi（或重连同一个 Wi-Fi 拿到新 IP），等待几秒后同一网址仍可访问。
5. 锁屏、退后台 10 分钟以上，网址仍可访问。
6. 两台设备同时运行时，第二台显示实际生效的 `localshare-2.local`，两个网址都能访问。
7. 在屏蔽组播的网络里，界面仍显示 IP 后备地址，并且能用它访问。
8. Release 包（已开启混淆）重复第 1、2 步。

## 涉及文件

- `android/app/build.gradle`：添加 JmDNS 依赖。
- `android/app/src/main/kotlin/com/lix/localshare/LocalHostnameAdvertiser.kt`：新建。
- `android/app/src/main/kotlin/com/lix/localshare/LocalShareForegroundService.kt`：管理广播生命周期和网络监听。
- `android/app/src/main/kotlin/com/lix/localshare/MainActivity.kt`：删除 NSD 注册，通道转发到服务。
- `lib/main.dart`：主机名设置、地址显示优先级、端口占用提示。
- `android/app/proguard-rules.pro`：新建，加入 JmDNS keep 规则。
