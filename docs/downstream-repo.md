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

**在线源路径要配 `EXTRA_SUITES`，否则镜像会整体落后于安装介质。** 厂商的基础 suite 是冻结的发布树，发布之后的构建放在独立的 `-updates` suite 里——通常就写在官方 sources.list 文档中，但很容易漏配。漏了的后果不是「稍旧」：麒麟 V10 SP1 的 215 个共有包里 150 个落后于 2503 介质，其中 `ca-certificates` 停在 2021-01，比介质旧三年。ABI 不受影响（`libstdc++6`、`libgcc-s1` 与介质完全一致，`libc6` 只差厂商构建号），但旧根证书会让构建期拉 https 失败而客户真机不会——**是假失败，方向比落后更糟**。配上更新源之后还要跑一次 `apt-get upgrade`：档位包逐包安装时自然取最新，但 `libc6`、`base-files`、`dpkg` 来自 debootstrap 阶段一，不升不动。这一步要硬失败：upgrade 非零退出，或者配了 `EXTRA_SUITES` 却一个包版本都没变（源没生效），都必须让构建挂掉，否则镜像会静默地继续发陈旧的包，而那正是配它要修的东西。

**发布之前拿 ISO 清单跟镜像对一次账。** 上面那个缺陷不会被任何现有门禁抓到——镜像能起、能编、符号版本对，全绿。它只在把镜像的 `dpkg-query -W` 输出与盘内装机清单逐包比对时才现形。用 `tools/iso9660.py` 走 HTTP Range 直读 `casper/filesystem.manifest`（或 `live/filesystem.packages`），各约 10 KB，不用下整盘：

```python
import sys; sys.path.insert(0, 'buildkit/tools')
from iso9660 import ISO
iso = ISO("<ISO 直链>"); e = iso.find("casper/filesystem.manifest")
media = dict(l.split()[:2] for l in iso.cat(e).decode().splitlines() if l.split())
# 与 docker run --rm IMG dpkg-query -W 的输出逐包比，落后的列出来
```

对不齐是常态，重点是**知道差在哪、并在 README 里如实写明**：镜像等于公开归档的状态，不等于某张具体介质。想要完全一致只有切那张盘，那是另一条路径——`slice` 路径的镜像天生没有这道缝，因为它本来就是从介质里切出来的。

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
