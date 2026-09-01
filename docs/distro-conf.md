# `distros/*.conf` 契约

每个被构建的系统版本对应一个 conf。它是 shell 片段，由 `build/build.sh` source 进来，因此可以写条件判断——按架构覆写某些键正是常见需求。

## 必填

| 键 | 说明 |
|---|---|
| `DID` | 版本标识，同时是产物文件名前缀。与文件名一致 |
| `DISPLAY_NAME` | 中文显示名，写进镜像标签 |
| `IMAGE` | 镜像名（不含 registry 与 tag） |
| `FAMILY` | `deb` 或 `rpm`。决定校验层用哪套判据 |
| `METHOD` | `mmdebstrap` / `selfhost` / `slice` / `rpmmedia` |
| `MIRROR` `SUITE` `COMPONENTS` | 在线源三要素。`slice` / `rpmmedia` 路径改用 `ISO_URL` |

## 分档

`MICRO_INCLUDE` `BASE_INCLUDE` `DEVEL_INCLUDE` 三个逗号分隔的包列表。`devel` 档实际安装的是 `BASE_INCLUDE` 加 `DEVEL_INCLUDE`，不要在 `DEVEL_INCLUDE` 里重复 base 的内容。

## 验收基线

`EXPECT_GLIBC` `EXPECT_LIBSTDCPP` `EXPECT_GLIBCXX` 用于与镜像内实测值对账。**这些值可能随架构不同**——同一个大版本的 LoongArch 移植可能落后一个 glibc 大版本，此时必须按架构覆写，否则门禁会用错误的基线判 PASS。

## 坏包处理

`REPACK_DEBS` 列出需要重打包的厂商包（典型是把 `Build-Depends` 误写成 `Depends`）。`STUB_PROVIDES` 列出由假包顶替的依赖，`PIN_NEVER` 列出永不安装的包。

后两者的取舍标准是：这个包在容器里有没有意义。内核态组件（initramfs、TPM、LSM 插件）一律没有意义，装了反而会按宿主内核打 initrd 或在缺少内核支持时崩溃；这类用假包或 pin 掉。有意义但坏掉的包才走 `REPACK_DEBS`。

## 按架构覆写的写法

```sh
COMPONENTS="main universe"
# LoongArch 的 libc6 在 main 而非 universe，component 顺序会影响解析
case "$ARCH" in
  loongarch64|loong64) EXPECT_GLIBC=2.28 ;;
esac
```

`ARCH` 在 source conf 之前就已由 `lib/arch.sh` 设好，可以直接用。
