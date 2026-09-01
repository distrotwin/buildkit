# buildkit

国产桌面操作系统容器镜像的公共构建机器码。各 OS 仓库以 submodule 方式引用本仓库，自己只提供 `distros/*.conf` 与一份调用可复用 workflow 的 yml。

这批镜像的目标是**造出与真实桌面系统尽可能一致的环境，用于软件构建与测试**。它们不是服务器基础镜像，也不面向生产部署：没有内核，部分内核态组件由假包顶替，systemd 只保留容器内有意义的部分。判断一个改动该不该做，标准是「它让镜像更接近真机、还是更方便部署」——只有前者属于本仓库的范围。

## 提供什么

| 路径 | 作用 |
|---|---|
| `build/build.sh` | 主入口。`build.sh <distro-id> <tier...>`，tier ∈ `micro` `base` `devel` |
| `build/build-selfhost.sh` | 自举两段式构建。宿主 dpkg 版本高于目标系统时走这条 |
| `lib/common.sh` | 公共函数：裁剪、内核链清理、时间戳归一、GPG 校验 |
| `lib/arch.sh` | 架构参数化：dpkg 架构名 → multiarch 三元组 / 期望动态链接器 |
| `test/inner-checks.sh` | 在镜像内运行的检查集，输出 `key=value` 供外层汇总 |
| `test/verify.sh` | 验收门禁：结构、完整性、能力、ABI 地板，与 conf 的预期基线对账 |
| `tools/gen-manifest.sh` | 产物清单，记录字节数与摘要 |
| `tools/mk-localrepo.sh` | 重打包厂商坏包（依赖字段写错等）后组成本地源 |
| `gate/` | ABI 地板测试程序的源码与编译脚本 |

## 四条构建路径

选哪条取决于目标系统能不能被在线 bootstrap，以及宿主与目标的 dpkg 是否兼容。

- **`mmdebstrap`** —— 在线源可直接 bootstrap，最省事
- **`selfhost`** —— 两段式。宿主 dpkg 写出的 `status` 目标系统读不了时必须走这条，第二段在目标环境内完成
- **`slice`** —— 从 ISO 里的 squashfs 切片，适用于没有可用在线源的系统
- **`rpmmedia`** —— rpm 系从安装介质引导

## 架构参数化

`ARCH` 取 dpkg 架构名，默认取宿主的 `dpkg --print-architecture`。`MULTIARCH` 与 `EXPECT_LOADER` 由 `lib/arch.sh` 查表得出，不做机械推导——`arm64` 的三元组是 `aarch64-linux-gnu`，`armhf` 还带 `gnueabihf` 后缀，推不出来。

**LoongArch 有两套互不兼容的 ABI，而且同一家厂商的不同版本各用一套。** 判据是动态链接器路径：

| dpkg 架构名 | 动态链接器 | 世界 |
|---|---|---|
| `loongarch64` | `/lib64/ld.so.1` | 旧世界 |
| `loong64` | `/lib64/ld-linux-loongarch-lp64d.so.1` | 新世界（上游 ABI） |

两者的 multiarch 三元组同名，产物却不可互换。

**旧世界在上游 QEMU 下跑不起来，这一点已实测。** 把目标系统的 `libc6` 与 `bash` 拼成最小 rootfs，用 `qemu-loongarch64-static -L <rootfs>` 直接执行：新世界的 bash 正常退出，内建变量 `MACHTYPE` 为 `loongarch64-unknown-linux-gnu`（编译期烧进二进制，可证明执行的是目标架构产物）；旧世界的 bash 停在动态链接阶段，`-strace` 显示它打开了目标 so、读出了 ELF 头，然后撞上 `Unknown syscall 80`。

syscall 79 与 80 是通用 Linux ABI 的 `newfstatat` 与 `fstat`。LoongArch 新世界去掉了这两个调用只保留 `statx`，上游 QEMU 的 loongarch64 target 因此没有实现它们，而旧世界的 glibc 仍在用。这不是缺库或路径问题，是系统调用 ABI 本身不同。

由此得到一条可复用的判据：**给一个陌生架构做镜像之前，先用「最小 rootfs + 只跑 shell 内建」验一次能不能真正执行。** 只用内建（`echo`、`$MACHTYPE`、算术展开）是关键——rootfs 里没有 `uname` 时，emulated shell 会沿宿主 PATH 执行宿主的 `uname`，输出宿主架构，看起来像是跑通了。

**component 布局可能随架构变。** 同一台归档上，`libc6` 在 amd64/arm64 下可能位于 `universe`，在 LoongArch 下却位于 `main`。`COMPONENTS` 只配一个值会得到一个没有 libc6 的源，而 `debootstrap` 报的错离真因很远。conf 里按架构覆写，不要照抄。

## 跨架构怎么跑

原生 runner 优先。GitHub 的 `ubuntu-22.04` 与 `ubuntu-22.04-arm` 都是原生，公开仓库免费，amd64 与 arm64 都不必模拟。只有 LoongArch 这类没有托管 runner 的架构才需要 QEMU。

需要模拟时，**宿主 `apt install qemu-user-static binfmt-support` 就够了**。不要引入 `tonistiigi/binfmt` 容器——实测它会破坏本来可用的 binfmt 注册，而且失效的真因往往是空实例遮蔽，不是宿主缺包。

## 下游仓库怎么接

```
你的仓库/
├── buildkit/              ← submodule，钉住一个 commit
├── distros/v11.conf
└── .github/workflows/build.yml
```

submodule 钉 commit 是刻意的：升级 buildkit 是一次显式提交，不会某天上游一改就让所有 OS 仓库集体漂移。

`distros/*.conf` 需要提供的键见 `docs/distro-conf.md`。最少要有 `DID` `FAMILY` `METHOD` `MIRROR` `SUITE` `COMPONENTS`，以及三档各自的 `*_INCLUDE`。

## 厂商镜像站的两类坑

**`Release` 会声明镜像站并不提供的索引。** 实测：麒麟 `dists/11.0/Release` 同时列出 `main/binary-arm64/Packages` 与 `Packages.gz`，而未压缩那个是 404，只有 `.gz` 存在。apt 在首选变体取失败后会回退到未压缩变体，撞上 404；mmdebstrap 的 `--error-on=any` 让它立即致命。因此构建时把 `gz` 提到 `Acquire::CompressionTypes::Order` 首位，让 apt 优先走确实存在的那个。

**debootstrap 会核对 suite 名，apt 不会。** 麒麟 `dists/4.0.2/Release` 里 `Suite` 与 `Codename` 都自称 `4.0.2-desktop`，于是 `debootstrap ... 4.0.2` 报 `E: Asked to install suite 4.0.2, but got 4.0.2-desktop from mirror` 而拒绝，而同一个源用 mmdebstrap 走 apt 则毫无问题。同一个源两个工具一个接受一个拒绝，这类差异只能靠实跑发现。conf 里的 `SUITE` 要写 Release 自述的那个名字。

## 超时与重试的相互作用

源对境外出口偶发卡死（返回 200、`Content-Length` 正确、body 0 字节直到超时），但吞吐本身不差——实测 1.45 MB/s，比国内直连快得多。所以重试有效，不必自建镜像。

**改超时之前先查清它的语义。** 这一条是踩了两次才写下的：`Acquire::http::Timeout` 是**不活动超时**而不是总传输时长上限——manpage 原文是 "this value applies to the connection as well as the data timeout"，只要数据在流就永远不触发，多大的文件都不会被它砍掉。

我第一次按「总时长」建模，算出「27 MB 在 45 秒内需要 590 KB/s」，据此把它从 45 秒放到 180 秒；结果单个卡死的包最坏要耗 `180 × Retries` 秒，devel 档几百个包，作业一小时跑不完。两次调整都基于同一个错误模型，方向相反、各制造一个故障。

正确的取值方式：`Timeout` 按「多久没有任何数据就判定卡死」来定（45 秒足够宽松），`Retries` 控制重试次数，两者相乘就是单个包的最坏耗时。curl 那边没有等价选项，用 `--speed-limit` 加 `--speed-time` 表达同一个意思，见 `lib/common.sh::fetch_exact`。

重试要放在**档位级**而不是只靠 apt 自己的 `Acquire::Retries`：后者只覆盖单次 `apt-get update`，而每个档位都要重跑一遍完整的 update 加 download。

另外，被重试包住的函数里不能用 `die`——`die` 是 `exit`，会把整个脚本带走，重试永远不会发生。这类失败要 `return` 非零。写完请做变异测试：让函数前两次失败第三次成功，确认确实调用了三次。「加了重试」和「重试真的会发生」是两件事。

## 取数纪律

外部索引与包体在下载途中被截断是常态，而下游工具**不会报错**：`zcat` 对截断的 gz 照常吐出前半段，`ar x` 对截断的 deb 少解一个成员也返回成功。据此得出的包数、版本、缺失清单全是假的。

因此凡是要据以下结论的下载，一律核对落地字节数与 `Content-Length` 严格相等，解压归档前先 `gzip -t`。`tools/` 下的脚本已经这么做，新增脚本请照办。
