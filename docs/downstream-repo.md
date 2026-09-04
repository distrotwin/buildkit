# 下游 OS 仓库建设规范

一个国产桌面 OS 一个仓库，共用本仓库这套机器码。`distrotwin/kylin` 是这套规范的第一个实现，后来的仓库照它建，不要另起炉灶。

规范管四件事：仓库长什么样、workflow 怎么组织、脚本放哪边、文档写什么。四件都有现成模板在 `templates/`，先复制再改，比从空文件开始快得多，也不容易漏掉门禁。

| 模板 | 复制到 |
|---|---|
| `templates/distro.conf` | `distros/<did>.conf`，一个版本一份 |
| `templates/build.yml` | `.github/workflows/build.yml` |
| `templates/README.md` | `README.md` |
| `templates/CLAUDE.md` | `CLAUDE.md`，再 `ln -sf CLAUDE.md AGENTS.md` |
| `templates/gitignore` | `.gitignore` |

## 前置之前：先确认 runner 拿得到材料

材料齐不齐，和 CI 拿不拿得到，是两个独立的问题。厂商站点常常只对国内出口放行，本机能下不代表 hosted runner 能下 —— 这一条卡死过两个候选系统，都是在写完 conf、准备开工时才发现的，所以要提到最前面来。

**判据只有一个：用 `probe-source.yml` 在 runner 上实测。** 本机结果不能替代，反过来也不行。探测清单里要放三样东西：目标 URL、同目录下一个必然不存在的路径（阴性对照）、以及同一厂商另一个域名（可达对照）。少了阴性对照，分不清「404 没有这个文件」与「一律超时/403 这台主机不给信号」；少了可达对照，分不清「这台主机不通」与「runner 到中国全断」。方德那次正是靠可达对照定的性：同一 runner 同一时刻，`www.nfschina.com` 1.7 秒 200、阴性对照 404，而 `updates.os.nfschina.com` 四个 URL 全部 135 秒超时。

探小文件，不要探 ISO。回答「这台主机通不通」几百字节的 `md5sum.txt` 就够了，把 4.7 GB 的 ISO 塞进探测列表只会让一次探测跑满四十分钟。大文件的下载能力交给构建本身去验，那里有重试和续传，失败时的诊断也更具体。

已探明的清单：

| 站点 | 本机直连 | GitHub runner | 结论 |
|---|---|---|---|
| 麒麟信安 ISO 站 | 403 | 403 | 真文件与不存在的路径同样 403，不给存在性信号 |
| 麒麟信安公开 rpm 源 | 200/404 分明 | 同左 | 可用，`kylinsec` 已上线 |
| loongnix 源 | 200 | 200 | 可用，`loongnix` 已上线 |
| 凝思 `www.linx-info.com` | 200 / 0.07 s | 000 / 135 s | **CI 不可行** |
| 方德 `updates.os.nfschina.com` | 200 / 0.09 s | 000 / 135 s | **CI 不可行** |
| 方德 `www.nfschina.com` | 200 | 200 / 1.7 s | 官网通，但上面没有包 |

凝思与方德都不是「材料不全」，是「材料在 runner 够不着的地方」，这一类可以靠数据镜像绕过去（做法见 [`srcdata.md`](./srcdata.md)：本机切料、经 GHCR 中转、runner 装配，凝思实测 4.3 GB 压到 178 MB）。凝思的下载目录开放可浏览、版本比研究记录里还多两个、本机那份 ISO 与官方 sha256 逐位一致；方德的更新服务器开着 autoindex，x86_64 有 9460 个包、aarch64 有 13869 个，repodata 完整。要接它们，只能换网络位置（自建国内 runner）或换取材方式，纯改 conf 无解。

**本机探测前先把六个代理变量全剥干净。** 环境里同时存在 `http_proxy`/`https_proxy`/`all_proxy` 三组大小写共六个，只 unset 其中两个或四个，curl 照样走代理、照样超时，而那个超时看起来和「站点不可达」一模一样。这个错误制造过一个假结论：本机的自造失败与 runner 的真实超时被归成同一个原因，反而显得交叉验证过了。代码里剥代理要按后缀剥（`k.lower().endswith("_proxy")`），不要列举变量名。

公共镜像站这条路对商业闭源国产 OS 不通：TUNA 的 182 个仓库里只有 `deepin` 与 `ubuntukylin`，USTC、NJU 同样没有方德、凝思、麒麟、UOS。不用再逐个猜路径。

## 前置：先去上游研究里取材

新建仓库之前，`hansbug-research/cn-desktop-os-image-from-iso` 的 `report.md` 里应该已经有这个系统的实测结论。至少要拿到六样东西，缺哪样就先去补哪样，不要靠猜：

| 要取的 | 用在哪 | 取不到时的后果 |
|---|---|---|
| 源地址与 suite 名 | `MIRROR` / `SUITE` | 最常见的坑，见下 |
| 包在 `main` 还是 `universe` | `COMPONENTS` | 只配 `main` 可能得到一个没有 libc6 的源 |
| glibc / libstdc++ / GLIBCXX 实测值 | `EXPECT_*` 基线 | 留空会被判通过，等于没有验收 |
| 厂商支持哪些架构、各架构是不是同一条产品线 | 矩阵与按架构覆写 | LoongArch 常常落后一代，用错基线会误判 PASS |
| 已知坏包与内核态组件 | `REPACK_DEBS` / `STUB_PROVIDES` / `PIN_NEVER` | 构建中途失败，报错离真因很远 |
| 这个系统能不能用某条构建路径 | `METHOD` | 选错路径会在很深的地方失败 |

**suite 名是重灾区。** 麒麟 V10 SP1 得用 `10.1` 而不是 `10.0`，后者是给已装机器推更新的差异源；V4 得用 `4.0.2-desktop` 而不是 `4.0.2`，因为 `debootstrap` 会核对请求的 suite 名与 `Release` 自述是否一致而 apt 不核对。新系统接入时，先把候选 suite 的 `Release` 拉下来读一遍 `Label` 与 `Suite` 字段，再决定。

## 从零到上线

1. 在 org 下建仓库，名字就是这个 OS 的通用简称（`kylin`、`uos`、`linx`），它同时是 GHCR 的镜像名
2. `git submodule add https://github.com/distrotwin/buildkit.git buildkit`，钉住一个 commit
3. 从 `templates/` 复制四份文件到位，按注释填空
4. **先在本地把一个版本的一个档位跑通**，别直接上 CI
5. 本地 `verify.sh` 全绿之后，再补齐其余档位与版本
6. 推仓库，用 `publish=false` 跑一轮完整 CI，确认构建与测试两阶段都绿
7. 看报告 artifact，确认没有异常项，`XFAIL` 都有据可依
8. 拿到授权后 `publish=true` 发布一轮
9. 用匿名视角验收 registry，然后把 README 里的版本号、tag、统计数字对齐到这一轮的实际结果

第 4 步不能跳。CI 一轮几十分钟，本地一个档位几分钟，把 CI 当实验台是这套流程里最贵的错误。

## 一、仓库形态

```
你的仓库/
├── buildkit/                     # submodule，钉住一个 commit
├── distros/<did>.conf            # 一个版本一个，文件名即 DID
├── .github/workflows/build.yml   # 只负责调用 buildkit 的可复用 workflow
├── README.md                     # 面向使用者
├── CLAUDE.md                     # 面向在这个仓库里动手的人与 agent
└── AGENTS.md -> CLAUDE.md        # 符号链接，不是副本
```

**下游仓库要薄。** 除了配置、调用 workflow 和文档，不放别的。写出了第五种文件就说明有东西该进 buildkit 了。

判断改动落在哪边只有一条：**只跟某个系统版本自己的事实有关**（源地址、suite、包列表、ABI 基线、这一版特有的怪癖）就进 `distros/*.conf`；**跟怎么构建、怎么测、怎么发有关**就进 buildkit。第二类占绝大多数。

`AGENTS.md` 用符号链接而不是复制，`git ls-files -s AGENTS.md` 应该看到 mode `120000`。两份副本迟早会分叉。

### `.gitignore`

直接复制 `templates/gitignore`，它覆盖构建产物、运行时状态、三种操作系统、常见编辑器与 IDE、Python 工具链、shell 与通用临时文件。

有两条通用模板里的常见规则**必须省掉**，照抄现成模板会踩：

- **不要写 Python 惯例的 `build/`。** buildkit 的构建脚本就在 `build/` 下，会被整个忽略掉。本项目不做 Python 打包，不需要这一条。
- **不要写 `*.gpg` / `*.key` / `keys/` 这类密钥通配。** 源的 keyring（`keys/*-archive-keyring.gpg`）是必须入库的公钥，不是私密材料，忽略掉会让构建在验签处失败。

运行时状态尤其不能入库。`gate/.gate-status` 记录的是「这个架构有没有低地板工具链」，由门禁脚本每轮重写、由验收脚本读取；它曾经被误提交，内容是 `GATE_LOW_OK=1`——某轮门禁脚本若没写成，验收就会读到这个陈旧副本，把「门禁不适用」当成「门禁通过」。

改完 `.gitignore` 之后要检查有没有误伤已入库的文件。`git check-ignore` 默认不把已跟踪文件算作忽略，必须加 `--no-index`：

```bash
git ls-files | while read f; do git check-ignore --no-index -q "$f" && echo "$f"; done
```

输出应该为空。若列出了东西，要么是规则太宽，要么是那个文件本来就该 `git rm --cached` 掉。

## 二、两处 pin 必须同步

submodule 钉脚本，`uses: distrotwin/buildkit/.github/workflows/*.yml@<sha>` 钉 workflow。两者必须是同一个 commit，`build-one.yml` 第一步就断言这件事：从 `.github/workflows/` grep 出所有 40 位 SHA，要求唯一且等于 submodule 的 HEAD。

不要试图用 `github.job_workflow_sha` 做这个断言，实测是空串。

```bash
git -C buildkit push origin HEAD
NEW=$(git -C buildkit rev-parse HEAD)
sed -i "s/<旧SHA>/$NEW/g" .github/workflows/build.yml
git -C buildkit checkout "$NEW"
git add buildkit .github/workflows/build.yml

# 验证而不是假设
git ls-files -s buildkit | awk '{print $2}'
grep -o '\.yml@[0-9a-f]*' .github/workflows/build.yml | cut -d@ -f2 | sort -u
```

钉 commit 是刻意的：升级 buildkit 是一次显式提交，不会某天上游一改就让所有 OS 仓库集体漂移。代价是每次升级都要走上面这套，所以**同时操作两个仓库时一律用绝对路径或 `git -C`**。靠 `cd` 建立目录上下文时，最麻烦的不是报错，而是命令静默作用到错误的仓库——打印出来的 short SHA 读起来像是另一个仓库的。

改了 buildkit 之后**不能用 `gh run rerun --failed`**：`uses:` 的 pin 钉在调用方 commit 上，重跑会照旧用旧版脚本。

## 三、`distros/*.conf`

字段契约见 [`distro-conf.md`](distro-conf.md)。这里只讲规范层面的三条要求。

**DID 之间不要有前缀关系，有的话要清楚哪些地方会踩。** 银河麒麟同时有 `v10` 与 `v10sp1`，前者是后者的前缀。制品名形如 `img-<did>-<arch>-<tier>`、日志名形如 `<did>-<arch>-<tier>.log`，凡是用 `<did>-*` 通配去挑自己的东西，都会把 `v10sp1` 的一并挑走。正确做法是取第一个 `-` 之前的字段做精确比对：

```bash
b=$(basename "$f"); [ "${b%%-*}" = "$D" ]
```

`actions/download-artifact` 的 `pattern` 只能用通配，躲不开这层重叠；好在多下载几个制品无害，真正要守住的是**读取时用精确路径**（`imgs/img-<did>-<arch>-<tier>/`、`find -name "<did>-<arch>-<tier>.json"`）而不是通配。

**`IMAGE` 必须按版本唯一。** 写成 `kylin-v11`、`kylin-v10sp1` 这种，不要三个版本共用一个 `kylin`。共用会让不同版本的镜像在同一台构建机上互相覆盖，症状是验收报「期望 2.38 实际 2.31」，读起来像构建错了，真因是 tag 撞车。

**`EXPECT_*` 宁可填推导值也不要留空。** 留空会因「期望空 == 实际空」被判通过，等于这一项验收不存在。填错会让门禁当场报错，那是好事。

**ISO 路径要显式钉 `SOURCE_DATE_EPOCH`。** 在线源那几条路径可以从 `Release` 的 `Date` 推导，切片没有源可推，`derive_epoch` 会退回一个常量——那是个假锚点，看起来有值而已。正确的值在 squashfs 超级块里（magic `hsqs` 之后的 `mkfs_time`），用 `iso9660.py` 读盘内 16 字节就能取到，而且**同版本不同架构要各钉各的**，实测同一天压制的两张盘能差几分钟。

**开了 multiarch 的系统，切片要挑对架构。** 国产桌面 OS 常带 i386 兼容层，`status` 里同名包有多条记录。按裸包名索引会让后解析的覆盖先解析的，于是 `libc6` 可能变成 `libc6:i386`，切片搬进 i386 的 `ld-2.28.so` 而漏掉 64 位的整套 glibc。症状离真因隔三步：镜像报 `exec /bin/bash: no such file or directory`，看着像 bash 没进去，实际是它的 ELF 解释器缺失；而 `ldconfig` 是 static-pie，唯独它还能跑，更容易把人带偏。`slice.py` 现在按 admindir 的 `arch` 首行挑本机架构，并对 `libc6` 做早失败断言。

**同一版本不同架构的表现差异是突破口，不是噪声。** 上面那个缺陷只在 amd64 出现，arm64 正常——因为 arm64 的解释器在 `/lib/ld-linux-aarch64.so.1`，而 `lib -> usr/lib` 那个软链在。定位时先问「另一个架构为什么没事」，往往比继续读同一份日志快。

**读日志读不出来时，把制品下下来直接看。** 构建产物就在 artifact 里，几十上百 MB，`docker load` 之后 `tar -tvf` 一览无余。上面那个缺陷我照日志猜了三轮（qemu、悬空符号链接、源里没有归档）全错，下载制品几分钟就有了确定答案。

**切片种子必须对着盘内清单逐个核，不能照抄另一个版本。** UOS V20 的种子照抄了 V25，而 Debian 10 那一代的装机清单里没有 `zstd`，直到切 base 档时才报「依赖未解析」。ISO 里就带着完整的装机清单（V20 是 `live/filesystem.manifest`，V25 是 `live/filesystem.packages`），用 `tools/iso9660.py` 直读几十 KB 就能核完，成本远低于跑一小时抽盘再失败：

```python
import sys; sys.path.insert(0, 'buildkit/tools')
from iso9660 import ISO
iso = ISO("<ISO 直链>")
e = iso.find("live/filesystem.manifest")          # V25 用 live/filesystem.packages
have = {l.split()[0].split(':')[0] for l in iso.cat(e).decode().splitlines() if l.split()}
print([s for s in SEEDS if s not in have])        # 应为空
```

**按架构不同的基线一定要写条件覆写。** 同一个大版本的 LoongArch 移植常常是独立产品线：麒麟 V10 SP1 的 loong 支是 Loongnix 血脉、glibc 2.28 + gcc 8.3，比 amd64 的 2.31 + gcc 9.3 落后一代；V11 两支编译器相同而 libstdc++ 差一档。用同一套基线会把差异掩盖掉。

**在线源路径要配 `EXTRA_SUITES`，否则镜像会整体落后于安装介质。** 厂商的基础 suite 是冻结的发布树，发布之后的构建放在独立的 `-updates` suite 里——通常就写在官方 sources.list 文档中，但很容易漏配。漏了的后果不是「稍旧」：麒麟 V10 SP1 的 devel 档对 2503 介质有 252 个共有包、171 个版本串不同，其中 22 个连上游版本都不同，`ca-certificates` 停在 2021-01、比介质旧三年。ABI 不受影响（`libstdc++6`、`libgcc-s1` 与介质完全一致，`libc6` 只差厂商构建号），但旧根证书会让构建期拉 https 失败而客户真机不会——**是假失败，方向比落后更糟**。配上更新源之后还要跑一次 `apt-get upgrade`：档位包逐包安装时自然取最新，但 `libc6`、`base-files`、`dpkg` 来自 debootstrap 阶段一，不升不动。这一步要硬失败：upgrade 非零退出，或者配了 `EXTRA_SUITES` 却一个包版本都没变（源没生效），都必须让构建挂掉，否则镜像会静默地继续发陈旧的包，而那正是配它要修的东西。

**发布之前拿 ISO 清单跟镜像对一次账。** 上面那个缺陷不会被任何现有门禁抓到——镜像能起、能编、符号版本对，全绿。它只在把镜像的 `dpkg-query -W` 输出与盘内装机清单逐包比对时才现形。用 `tools/iso9660.py` 走 HTTP Range 直读 `casper/filesystem.manifest`（或 `live/filesystem.packages`），各约 10 KB，不用下整盘：

```python
import sys; sys.path.insert(0, 'buildkit/tools')
from iso9660 import ISO
iso = ISO("<ISO 直链>"); e = iso.find("casper/filesystem.manifest")
media = dict(l.split()[:2] for l in iso.cat(e).decode().splitlines() if l.split())
# 与 docker run --rm IMG dpkg-query -W 的输出逐包比，落后的列出来
```

判「差多少」时要把**厂商构建号不同**与**上游版本也不同**分开：前者是同一份上游代码重新打包，后者才是真落后。切版本串时不能按最后一个 `-` 切——国产厂商的版本常常没有 `-`（`11kylin5k13.5`），那样会把纯构建号差异全判成上游差异，实测把 V10 SP1 的真实差异从 6 项夸大到 17 项。按第一个 `-`、`~` 或厂商标记（`kylin` / `ok<数字>`）之前切才对。

对不齐是常态，重点是**知道差在哪、并在 README 里如实写明**：镜像等于公开归档的状态，不等于某张具体介质。想要完全一致只有切那张盘，那是另一条路径——`slice` 路径的镜像天生没有这道缝，因为它本来就是从介质里切出来的。

### 单架构 + 无托管 runner 的形状

龙芯 Loongnix 是第一个这种被试：全线只有 LoongArch，没有 amd64/arm64，而 GitHub 没有 LoongArch 托管 runner。于是 workflow 里没有架构矩阵，三个档位全靠 QEMU 用户态模拟，`runner: ubuntu-24.04` + `needs-qemu: true`。这不是特例处理，是这一类被试的正常形状：矩阵维度少一个，单 job 时间长一个数量级。

**世代判据落在动态链接器上，不在架构名上。** LoongArch 有两套互不兼容的 ABI，而命名在两个包生态里不一致：deb 世界 `loong64` 是新世界、`loongarch64` 是旧世界，**rpm 世界两个世界都叫 `loongarch64`**。所以接一个 LoongArch 被试的第一件事是读它 `Release`／`repodata` 的架构字段**再**验解释器：`/lib64/ld-linux-loongarch-lp64d.so.1` 是新世界，`/lib64/ld.so.1` 是旧世界。

**旧世界在托管 runner 上造不出来，这一条已两次实测。** 上游 QEMU 不实现旧世界那两个系统调用，症状是拿一个旧世界二进制直接跑就报 `Unknown syscall 80`（ENOSYS，表现为 `cannot stat shared object: Error 38`）。麒麟 V10 SP1 的 `loongarch64`、Loongnix 20、方德 4.0 的 `LoongarchOS` 都是这样（方德那支 filelists 里 `/lib64/ld.so.1` 命中、`ld-linux-loongarch-*` 零命中，配 glibc 2.28 与 `.lns8` 包标记，不必再建一轮就能判死）。**判据是执行结果，不是架构名或 glibc 版本**——五分钟就能测完：从源里拉 `bash` 与 `libc6` 的包，解开，用目标自己的解释器加 `--library-path` 跑一句 `echo`。接任何 LoongArch 被试都该先做这一步，别等建完一轮才发现。

**没有低地板可比时，检查项要标「不适用」而不是「通过」。** `manylinux2014` 没有 LoongArch，而它最早的 glibc 已高于 2.17，所以「产物是否依赖过新符号」这一项在这个架构上无从比较。检查集按架构分支给出「不适用」，这会让报告的通过数比本地 `verify.sh` 的总数少（每个镜像少一条），对齐基线时要按报告的口径而不是本地总数。

### LoongArch 旧世界：别做，先看这一节

**结论:上游 QEMU 造不出旧世界(`loongarch64`)的镜像,不要再花时间修 binfmt。** 这一节把 2026-09 那次逐层排查完整记下来,因为报错文案会把人一路引向错误的子系统,我在上面耗了七轮。

前三层都是通的,能过并不代表能成:

| 层 | 结论 | 花在这里的弯路 |
|---|---|---|
| 简单二进制能否执行 | **能**,QEMU ≥ 9。8.2.2 报 `Unknown syscall 80`,上游 9.x 补了 stat 那两个调用 | Ubuntu 24.04 只带 8.2.2、无 backports;Debian 13 的 `qemu-user` 里那个二进制是 **static-pie、零 glibc 依赖**,可直接搬到 runner 用 |
| binfmt 能否配对 | **能**,但有两处陷阱 | Ubuntu 的 `qemu-user-static` **不给 loongarch64 提供 `update-binfmts` 定义文件**,`--enable`/`--import` 都无从下手,只能 `--install` 自己建条目;而 builder 容器有**独立的** `/var/lib/binfmts`,宿主注册好不等于容器里查得到 |
| mmdebstrap 能否放行 | **能**,要显式关一道预检 | 它的判据是 `arch-test <arch>`,而 `arch-test` 只有 `loong64` 那一份 helper,对 `loongarch64` 回答 `I don't know how to detect arch 'loongarch64', sorry.`——**它回答的不是「能不能执行」而是「我认不认识这个名字」**,binfmt 配得完美它也不会去问。用官方的 `--skip=check/qemu` 绕过 |
| **装包能否完成** | **不能** | 见下 |

最后一层是硬墙。同一个 QEMU 10、同样的操作:

```
旧世界:  rt_sigaction(SIGQUIT, ...) = -1 errno=22 (Invalid argument)
         rt_sigaction(SIGCHLD, ...) = -1 errno=22
新世界:  rt_sigaction(SIGQUIT, ...) = 0
```

dpkg 在跑维护者脚本之前必须 `signal(SIGQUIT, SIG_IGN)`,拿到 EINVAL 就中止:

```
dpkg: unrecoverable fatal error, aborting:
 unable to ignore signal Quit before running new libc6:loongarch64
 package pre-installation script: Invalid argument
```

根因是旧世界内核有自己的 `sigaction` 结构体布局,与上游不同;上游 QEMU 补了 stat 那两个系统调用,没补信号那一套。要做旧世界镜像只有龙芯补丁版 QEMU 或真机两条路。

**这一节最该记住的一条判据错误:「能执行」与「能装包」是两个命题。** 我拿旧世界的 `bash`／`busybox` 打出 `MACHTYPE` 就宣布可行,而 `busybox` 连 `trap "" QUIT; echo ok` 都打得出来——**只因为它不检查 `rt_sigaction` 的返回值**,dpkg 检查了。验一个新架构的可行性,第一步就该是**跑一次真实的 dpkg／rpm 装包**,而不是 `echo`。

同理,`tools/ensure-qemu.sh` 与 `probe-qemu-oldworld.yml` 都留着——它们对「换 QEMU 版本」这件事本身是对的,将来上游补上信号支持就能直接用;`ensure-qemu.sh` 的架构表里把要求写成数据,新架构只加一行。

### deb 系再补三条

**`gpgv` 要显式列进 base 档。** 出厂 `sources.list` 用 `signed-by=`，apt 验签要调 `gpgv`，而 Debian 里 `gnupg` 只 Recommends 它、不 Depends；构建时关了 recommends，于是镜像里没有 `gpgv`，`apt-get update` 报 `Internal error: Cannot find gpgv ... InRelease is not signed`。那句话读起来像「源没签名」，真因是镜像里缺验签工具。

**本地源只在真的存在时才写进源列表。** `copy://$ROOT/localrepo/$DID` 服务的是 `REPACK_DEBS` / `STUB_PROVIDES`，两者都为空时 `mk-localrepo.sh` 压根不跑、目录也不存在，而无条件写那一行会让 apt 报 `Err:3 copy:/w/localrepo/<did> ./ Packages` 然后 `mmdebstrap` 整体失败。前三个被试都至少有一项非空，所以一直没暴露。

**本地跑构建时代理变量要大小写四个都清。** 容器会从 docker daemon 的 proxy drop-in 继承设置（本机是 `10.3.32.34:17777`），而那个代理在容器里往往连不上。只清小写两个不够，症状是取 `InRelease` 五轮重试全失败、报错指向「软件源不可达」，而同一个地址在宿主上 200。CI runner 没有代理，所以这一条只在本地预演时踩到——而本地预演正是制度要求的第一步。

### rpm 系特有的坑

第一次接 rpm 系（麒麟信安）时踩的，都不是这一家特有的。

**「包有签名」不等于「签名可验」，公钥拿不到就别声称验了签。** 方德的包 PGP、DSA、RSA 三个 signature tag 齐全，但签它的 key（x86_64 是 `9D46A40588FBDABE`，aarch64 与 loongarch64 是 `6AB01E082F1E26FE`）在任何能拿到的地方都没有：`nfs-release` 里带的两把对不上，专用的 `nfs-gpg-keys` 包里装的是 **Oracle OSS group 的公钥**和一把 uid 写着 `private OBS (key without passphrase)` 的 OBS 默认无口令 key，公开 keyserver 两家都 404，而厂商自己的 `Nfs-Base.repo` 就写着 `gpgcheck=0`、baseurl 还是 `ftp://`。遇到这种情况，能拿到的最强锚点是厂商发布的校验和清单（方德是 `sm3sum.txt`，12610 行），但那只防传输损坏、不防替换，性质与签名不是一回事，README 里不能混着写。


**先探宿主可达性，再定取材路径。** 厂商放 ISO 的那台主机和放软件源的那台主机是两回事，可达性要分别验。麒麟信安的 `mirrorlists.kylinsec.com.cn` 对 GitHub runner **全量 403**，且真文件与不存在的路径同样 403（不给存在性信号）；而它的公开 rpm 源 `mirrorlist.kylinsec.com.cn:8888`（主机名单数、端口不同）200/404 分明、秒级可达。用 `probe-source.yml` 从 runner 那个网段探，别用本机的结论下判断——本机还可能因为继承了 `https_proxy` 而把请求送到境外出口，表现成一样的 403。

**跨发行版 bootstrap 只能 `--noscripts`，而 `%post` 承担了一部分文件系统状态的构造。** 于是 rpm 的文件清单**系统性地过度承诺**：它声明的一部分路径要靠脚本才真的出现。这一族缺陷的共同形状是「包数据库自洽、文件系统不自洽」，所以 `rpm -qa`、`rpm -V --nofiles` 全都过，只有真去用那个文件才暴露。已知要逐类重放的有四项，判据一律挂在产物上而不是「脚本跑过了」：

| 被跳过的 `%post` | 症状 | 判据 |
|---|---|---|
| `update-ca-trust extract` | CA bundle 是悬空软链，所有 TLS 握手失败 | bundle 存在且够大 |
| `ldconfig` | `/etc/ld.so.cache` 从未生成 | cache 非空，且 `systemctl` 真能跑 |
| `update-crypto-policies` | `back-ends/` 空，指进去的软链成片悬空 | 目录非空 |
| `alternatives --install` | 清单里有 `/usr/bin/ld` 而文件不在，`collect2: cannot find 'ld'` | 链接真的出现 |

最后一项只在麒麟信安 V3.4 上暴露、V6 不受影响（它的 binutils 直接给出 `/usr/bin/ld`），又一次印证「同一族系不同版本的差异是突破口」。做法是只从 scriptlet 里抽 `alternatives --install` 那几条执行（实测全部已装包里只有 3 条），不跑厂商任意脚本；续行要先拼起来，否则四个参数会被截断。

**数据库后端可能两端没有交集。** 装库用的是 builder 的 rpm，读库的是目标自带的 rpm。麒麟信安 V3.4 的 rpm 4.15.1 **只支持 bdb**，而 builder 的 rpm 4.20 自 4.19 起去掉了 bdb 写支持——更麻烦的是指定 `bdb` 它会**接受参数、返回 0、一个文件都不建**。这种静默无操作会让后面每一步都「成功」，直到最后 `rpm -qa` 读出 0 个包，而那个症状与「空镜像」不可区分。两条应对：`initdb` 紧后面就断言真的建出了数据库文件（判据前移的价值在于报错离真因更近）；两端谈不成时用 `RPM_DB_VIA_TARGET=yes`，文件由宿主 rpm 落位、包登记交给目标自己的 rpm 用 `--justdb` 重做。

**厂商自带的 repo 要停掉，只留自己验证过的那份。** `<厂商>-release` 包会装一批 `enabled=1` 的 repo，指向一个 mirrorlist 服务，而那个服务**并不覆盖所有版本×架构组合**（实测 `osversion=6 & repo=update & arch=loongarch64` 返回 0 个 URL）。dnf 遇到一个取不到元数据的 repo 会**整体失败**，不会因为「还有另一个可用的 repo」而放过——所以只追加自己那份等于让整个包管理器不可用。处理成 `enabled=0` 而不是删文件，并加一道结果判据：除自己那份以外不许再有 `enabled=1`（「跑过一遍 sed」不算数，厂商换个写法就会漏，而漏掉时 `has_source` 照样是 Y）。

**出厂源要写 repo 文件加公钥两件。** 只写 repo 文件而不把公钥放进 `/etc/pki/rpm-gpg/`，dnf 会在首次装包时停下来问是否导入 key，非交互下表现为装不上，而 `has_source` 照样是 Y。`gpgcheck` 一律开：关掉它能让往返检查更容易过，但那是把判据往下调去迁就实现。

**`rpm -K` 的判据必须是字面 `signatures OK`。** 未签名的包 `rpm -K` 会打印 `digests OK` 并返回 0——只看退出码或只找子串 `OK` 会让无签名的包蒙混过关，而 `NOT OK` 里也含 `OK`。另外 rpm 4.20 起用 Sequoia 做 OpenPGP 后端，默认策略拒绝 SHA-1 的密钥绑定签名，报错写「No binding signature at time <现在>」读起来像密钥过期，实际被拒的是哈希算法；放宽这一条是可接受的，因为信任根是导入前核过的**指纹**，不是 key 自签名的抗碰撞性。

**LoongArch 的世代不能靠架构名判。** deb 世界用名字区分（`loongarch64` 旧、`loong64` 新），而 **rpm 世界两个世界都叫 `loongarch64`**。判据落在动态链接器上：`/lib64/ld-linux-loongarch-lp64d.so.1` 是新世界，`/lib64/ld.so.1` 是旧世界。上游 QEMU 只实现新世界，所以这一项直接决定这一支能不能在托管 runner 上造出来。

**包管理往返的上限要按源的地理位置给。** 原来写死 180 秒，而国内源配境外 runner 拉一个 15000 个包的仓库元数据要几分钟：实测 CI 上那一步整步 189 秒、上限 180，于是判定「镜像装不上包」，而本地同一个镜像装得上。**同一份镜像在两个网络位置得出相反结论**时，先怀疑判据把网络距离算成了缺陷。

## 四、workflow 组织

下游只写一份 `build.yml`，它只做两件事：定义矩阵、调用 buildkit 的可复用 workflow。所有实现都在上游。

**三个阶段严格串行，一个都不能合并：**

| 阶段 | 粒度 | 为什么 |
|---|---|---|
| 构建 | 每个「版本 × 架构 × 档位」一个 job | 三合一时一个档位失败会拖垮另外两个，且日志混在一起 |
| 测试 | 同样粒度，在**干净机器**上装载后跑 | 构建机的状态（builder 容器、本地源、宿主装的包）会掩盖镜像自身的缺陷 |
| 发布 | 每个「版本 × 档位」一个 job，内部处理该档位全部架构 | manifest list 要把各架构合到一起 |

发布必须 `needs` 测试与报告都成功，且**不能塞进构建或测试阶段里**。

**唯一允许放宽构建粒度的情形：该路径有昂贵的共享前置。** 切片路径要先抽几个 GiB 的 squashfs 再解包，三个档位各做一遍等于白花两遍，而解开后的 rootfs 塞不进 `actions/cache` 的 10 GB 上限。这种情况下按「版本 × 架构」切分构建、一个 job 出三个镜像是允许的（见 `build-slice.yml`），但**测试粒度不许跟着放宽**：一镜像一 job、干净机器装载这条要守住，「构建机状态会掩盖镜像缺陷」的风险在测试端，那才是要紧的地方。

**触发方式固定为 dispatch only。** 一轮几十个 job、拉几个 GB，不接受 push 触发。两个输入开关：

- `publish`：默认 `false`，只有明确要发布时才开
- `include-<某架构>`：需要模拟才能构建的架构默认关，例如 loong64 要 QEMU 且 devel 档约 30 分钟

**重试用现成的 action，不要自己写循环。** 统一用 `nick-fields/retry`，脚本本身只管跑一次。手写重试等于把「重试几次、等多久」的策略从工具里挪到我们的代码里再实现一遍。

**日志不要折叠、不要吞。** 构建与测试阶段的每一步都直接打在控制台上，展开到 info/warning 级别。用 `tee` 落一份到 artifact 时记得 `set -o pipefail`，否则管道会吃掉退出码。

## 五、脚本组织形态

buildkit 内部的分层是固定的，新增东西时按这个分：

```
lib/       共用函数与架构参数化，被所有脚本 source
build/     四条构建路径的实现，按 METHOD 分派
test/      验收：verify.sh 在宿主编排，inner-checks.sh 在镜像里跑
gate/      ABI 门禁的探针源码与产物
tools/     独立小工具（取配置、造本地源、渲染报告）
docs/      契约与规范
templates/ 下游仓库的起始模板
.github/workflows/  可复用 workflow，一个阶段一个文件
```

几条硬性要求：

**`BK` 与 `ROOT` 不是一回事。** `BK` 是 buildkit 自己的根（`lib`/`build`/`test`/`tools`/`gate` 在这里），`ROOT` 是项目根（`distros`/`out`/`localrepo`/`keys` 在这里）。submodule 布局下两者不是同一个目录，混用会在「找得到 conf 却找不到 common.sh」这种地方失败，报错离真因很远。

**取配置只走 `tools/conf-get.sh`。** 它负责先 source `lib/arch.sh` 再 source conf。直接 source conf 会在 `ARCH` 没设时炸在 `ARCH: unbound variable`，而那个报错会让人误以为是网络或源的问题。

**不允许「退出码 0 但没有产物」。** 每条构建路径末尾都要有出口断言。曾经有一条路径遇到不支持的 `METHOD` 时打印一句提示就 `exit 0`，上层完全看不出来。

**`die` 不能用在需要重试的地方。** `die` 是 `exit`，写在取数函数里会让外层的重试永远拿不到第二次机会，应该 `return 1`。

**循环体里的条件动作写 `if`，不要写 `[ 条件 ] && 动作`。** 后者作为 `while` 循环体的最后一句时，最后一次迭代若条件为假就返回 1，`while` 跟着返回 1；若这个 `while` 又在管道里（`find ... | while`），管道返回 1，`bash -e` 直接判整步失败。这个缺陷特别能骗人：产物已经正确生成，步骤却红着退出，而且只有「自己的东西恰好排在末尾」的那一路侥幸通过，看起来像随机失败。

**门禁不能和它要守的前提共用同一个 `if`。** 加 `EXTRA_SUITES` 时我在 inner 脚本里写了两条硬断言（"配了却没有任何包版本变化就失败"），但它们都在 `if [ -n "${EXTRA_SUITES:-}" ]` 里面，而真正失效的恰恰是这个变量本身——`build-selfhost.sh` 用显式 `-e` 白名单往容器传变量，漏了它。于是整块代码连断言一起被跳过，六个构建全绿，发出去的镜像和改动前一字不差。**守卫与被守卫的东西共享同一个前提时，守卫就是空的。** 正确做法是把判据放到别处或挂在产物上：一道在容器建好后 `docker inspect` 核 `Config.Env` 里的值等于 conf 的值（在 inner 之外），一道在 `docker export` 之后核出厂 `sources.list` 真的含每个更新源（挂在产物上），原有那道留在 inner 里作为第三重。

**不要用 `set +e` / `set -e` 捕获退出码。** `set -e` 作用于整个 shell 而非单条语句，所以在一个本来只开 `set -u` 的脚本里"临时关掉再打开"，等于给后续所有代码悄悄换了一套失败语义。实测后果：`lib/common.sh` 里 `rm -f /etc/hostname /etc/resolv.conf /etc/hosts`（容器内这三个是 docker 的 bind mount，必然 EBUSY，而删不掉毫无后果——bind mount 的内容不会进 `docker export`）存在很久、一直在打印错误、一直无害，被泄漏的 errexit 一下变成中止构建。写成 `cmd || _rc=$?`：只影响这一条语句，且在 errexit 开着的脚本里同样安全，因为 `||` 的存在本身就让 errexit 不触发。

**全量 `apt-get upgrade` 会碰到带 systemd unit 的包，容器里必挂。** 逐包安装档位包碰不到这个问题——档位清单里那些包都不带 unit。一旦做全量升级，`postinst` 里调 `systemctl` 的包就会报 `System has not been booted with systemd as init system (PID 1). Can't operate.`（麒麟 V10 SP1 的 `kyseclog-daemon` 就是）。两条拦截路径都要堵：`policy-rc.d` 返回 101 只被 `invoke-rc.d` 与 `deb-systemd-invoke` 尊重，直调 `systemctl` 绕过它，得用 `dpkg-divert` 把 `systemctl` 临时改道到 `/bin/true`；`systemctl` 压根不存在时也要铺一个 stub，否则 postinst 会以"命令找不到"失败、症状不同后果一样。**改道必须在升级后撤掉并断言撤回成功**——出厂镜像若带一个指向 `/bin/true` 的 `systemctl`，在镜像里毫无症状，所有检查都会过，用户直到要管服务时才发现。判据写成"它还指不指着 `/bin/true`"加"divert 表里还有没有那条"，不要写成"必须是真文件"：有的系统里 `systemctl` 本身就是软链，那样会误杀。

## 六、门禁

下面这些是发布路径上的最低配置，新仓库不能少。每一条都对应一个真实发生过的缺陷。

| 门禁 | 防的是什么 |
|---|---|
| submodule 与 workflow 的 pin 相等 | 跑的脚本不是你以为的那份 |
| 构建出口断言：有产物才算成功 | 静默 `exit 0` |
| 各架构制品的层指纹互不相同、平台戳符合预期 | 本地 tag 撞车导致多个架构指向同一份 rootfs |
| 打 label 前后语义字段逐项不变 | `docker commit` 把容器状态（如宿主的 proxy 环境变量）烧进镜像 |
| 任何 label 的值不得为空 | 空值 label 看起来像「量过了，值就是空」，比缺失更糟 |
| 发布后校验 manifest list 的平台集合与成员 digest 数 | 各架构指向同一份镜像时，manifest list 照样建得出来 |
| 报告层的期望值与基线对账 | 检查项悄悄减少而报告仍然全绿 |

**判据挂在结果上，不要挂在机制或字面上。** 这条在接入统信 UOS 时连栽三次：`has_cxx` 与 `apt_roundtrip` 的分支用 `IMMUTABLE=yes` 开门，而那是「是不是 OSTree 不可变系统」的事实，被当成了「有没有 g++」「有没有可用 OS 源」的代名词——V20 不是不可变系统却同样两样都缺，于是走错分支；locale 的拷贝守卫写成「目标目录不存在才搬」，而切片会按包清单建出空目录，条件永假；`apt_roundtrip` 的无源判据写成匹配 `N*not-installed*`，而括号里那串是 dpkg 状态库的偶然写法，换一版就变成 `N(未装)`。

三处的共同点是：真正要断言的东西（有没有 C++ 工具链、装没装上包、镜像里有没有 zh_CN）都很好判，而代码却去判了一个碰巧相关的中间物。写检查时先把「我到底要断言什么」写成一句话，再看条件是不是在直接判它。需要按发行版分支时，用 conf 里显式声明的期望（`EXPECT_CXX`、`EXPECT_OS_REPO`），不要拿别的事实当代名词。

**加门禁时要对门禁本身做双向变异测试**：制造它该拦的情形确认真拦得住，制造它该放行的情形确认不误伤。有一道门禁只验了单向就上线，把九个发布 job 全卡死——判据写成了「除 Labels 外全等」，而 `docker commit` 合法地会改 `Hostname`、`Image`、`AttachStdout/Stderr`。正确写法是显式列出必须不变的语义字段。

## 七、README 写法

面向的是「想在这个系统上编东西的人」，不是本项目的开发者。章节骨架照抄，顺序不要动：

| 章节 | 要回答什么 |
|---|---|
| 标题 + 一条命令 | 这是什么，以及立刻能看到点东西 |
| 这是什么，不是什么 | 边界。该用什么场景、不该用什么场景，各自列清 |
| 先跑一遍 | 进容器写个最小程序、编了跑，给命令也给期望输出 |
| 选哪一个 | 版本表（含 glibc / 编译器 / 上游血脉 / 架构）与档位表，各带选型指引 |
| 怎么用 | 若干可直接粘贴的场景：查 ABI 需求、多版本齐验、在 CI 里当构建环境、打包、跨架构 |
| 认出自己在哪个系统上 | `cat /etc/os-release` 原生输出，每个版本各贴一份 |
| tag 与钉版 | tag 表、日期 tag 的语义、要钉死请用 digest |
| 溯源 label | 表格列出每个 label 的含义 |
| 架构与 ABI 分叉 | 同版本不同架构的差异，以及某些架构为什么没有 |
| 已知的怪癖与期望失败 | 用户会撞见并误以为是 bug 的现象 |
| 镜像是怎么造的 | 走哪条路径、踩过哪些坑、验收强度 |
| 本地构建 | 完整可执行的命令序列 |
| CI | 触发方式与两个开关 |
| 仓库结构 | 目录说明与上游链接 |

硬性要求：

**每条命令和每段输出都必须实跑核对过。** 把文档里的代码块原样抽出来执行一遍，别凭记忆写。曾经因为把 `gcc` 元包版本当成编译器版本，README 上的三个版本号全错。

**版本号一律来自跑镜像实测。** `gcc -dumpfullversion`、`ldd --version`，不要取源索引里的元包版本。

**「认出自己在哪个系统上」直接贴 `cat /etc/os-release` 的原始输出**，不要拼装脚本。厂商写在 `VERSION` 里的中文系统名是最直接的证明。

**中文，自然段内不换行**，一段写成一行长句。不写空洞的总结句和收尾金句，不用「不是 X 而是 Y」的对仗撑气势。

## 八、`CLAUDE.md` 与 `AGENTS.md`

面向在这个仓库里动手的人和 agent，与 README 分工明确：README 讲怎么用镜像，CLAUDE.md 讲怎么改这个仓库。必须覆盖：

- 硬性约定（commit 不允许带 co-author、文档语言与换行、写文档的取数纪律）
- 这个仓库放什么、什么该进 buildkit
- 配置文件逐字段说明与改动注意
- 改动到跑通的完整回路，含两处 pin 的同步与**验证**命令
- 本地构建与验证的完整命令（每条路径一套）
- CI 触发方式与开关
- 必知事实：这个系统特有的、实测踩出来的坑
- 门禁清单与各自防的缺陷
- 发布与验收方法
- 排错原则

**不要在 CLAUDE.md 里绑定具体的人名或邮箱。** 提交身份由本地 git 配置决定，文档里只写「不允许带 co-author」。

「必知事实」那一节是这份文档最值钱的部分，写的时候只收**实测踩出来的**结论，每条都要说清现象、真因、以及照着直觉改会走到哪个错误方向。

## 九、发布与验收

tag 方案统一：

```
ghcr.io/distrotwin/<镜像名>:<版本>-<档位>
```

- 不带档位后缀的 tag 指向 `devel`
- `latest` 是最高版本的 `devel`
- 每个档位同时打带日期的 tag，日期取**发布时仓库 HEAD 的 commit 日期**（UTC），不是构建时刻
- 每个架构另有单架构 tag，是 manifest list 的成员

日期 tag 是约定不动而非强制，同一天内重复发布会覆盖它——允许，但发布日志要打印被覆盖的旧 manifest 摘要。要真正钉死只能用 `@sha256:`。

**首次发布后包是私有的**，GHCR 容器包的可见性没有 REST 接口，要到包设置页手动改成 public，否则 README 里的 `docker pull` 对外人不可用。

**验收不看 CI 自己的日志**，用匿名视角查 registry 里真实躺着什么：

```bash
TOK=$(curl -s "https://ghcr.io/token?scope=repository:distrotwin/<镜像名>:pull&service=ghcr.io" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  https://ghcr.io/v2/distrotwin/<镜像名>/manifests/<tag> | python3 -m json.tool
```

要看四件事：平台集合对不对、成员 digest 是否两两不同、config blob 里的 label 有没有空值、平台戳与 `cn.internal.arch` 是否一致。

## 上线检查清单

- [ ] 上游研究里六样信息齐全，suite 名读过 `Release` 确认
- [ ] `IMAGE` 按版本唯一
- [ ] `EXPECT_*` 无空值，按架构有差异的已写条件覆写
- [ ] 本地跑通至少一个版本的全部三档，`verify.sh` 全绿
- [ ] 两处 pin 相等，且是打印出来比对过的
- [ ] `publish=false` 跑完一整轮 CI，构建与测试两阶段全绿
- [ ] 报告 artifact 里没有异常项，`XFAIL` 每条都有真机依据
- [ ] `AGENTS.md` 是符号链接（mode `120000`）
- [ ] `.gitignore` 已就位，`git check-ignore --no-index` 对已跟踪文件输出为空
- [ ] README 每条命令实跑核对，版本号取自镜像实测
- [ ] CLAUDE.md 覆盖第八节列的十项，且不含具体人名
- [ ] 发布后匿名验收四项通过
- [ ] GHCR 包已改为 public

## 设计取舍

**为什么每个 OS 一个仓库而不是一个大仓库。** 各系统的发布节奏、架构支持、坏包清单彼此无关，合在一起会让任何一次改动都要重跑全部。代价是机器码要抽出来共用，于是有了 buildkit 加 submodule。

**为什么 submodule 钉 commit 而不是跟 main。** 跟 main 意味着上游一改，所有下游仓库的构建行为同时变化，而且变化不体现在下游的提交历史里。钉 commit 把升级变成一次显式提交，出问题时能二分。

**为什么构建与测试要分两个阶段、跑在不同机器上。** 构建机上有 builder 容器、本地源、为构建装的一堆包，镜像里缺什么都可能被这些掩盖。测试阶段从 artifact 装载镜像、在干净机器上真正启动，测的才是别人 `docker pull` 下来会拿到的东西。

**为什么发布阶段不重建镜像。** 发布只做打 label、推 tag、合 manifest。任何在测试之后改变镜像内容的动作，都会让「测过的」和「发出去的」不是同一个东西。

**为什么期望失败要显式声明而不是放宽检查。** 老系统上有些检查注定红，判据是「这个现象在真机上也一样吗」。一样就进 `XFAIL`，报告里标 🟡 但不计失败；而且**居然通过了要报 xpass**，提醒把豁免收回。放宽检查会让这条豁免永远挂着，掩盖以后真正的回归。

**为什么报告要按系统分文件、日志要全量进 artifact。** 一个 markdown 挤下所有系统会没人看；出问题时需要的是当时的完整日志，包括成功的那些——只留失败的日志，就没法比对「同样的步骤在别处是什么样」。
