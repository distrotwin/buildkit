# 开发指引

`distrotwin` 各 OS 仓库共用的构建机器码。下游仓库以 submodule 引用本仓库并钉住 commit，所以**这里的每一次改动都会在下游显式升级时才生效**，但一旦生效就影响全部 OS 仓库。

新建一个 OS 仓库要读的是 [`docs/downstream-repo.md`](docs/downstream-repo.md)，那是下游仓库的建设规范；本文件讲怎么改本仓库。

## 硬性约定

- commit **不允许带 co-author**
- 文档一律中文；Markdown **自然段内不换行**，一段写成一行长句
- 不在仓库里讨论许可与法务
- 改动同时影响多个下游仓库，所以本仓库的改动必须先在至少一个下游仓库上本地跑通再推

## 目录分层

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

新增东西时按这个分。写出了不属于任何一层的文件，先想清楚它是不是该待在下游。

## 四条构建路径

| METHOD | 适用 | 要点 |
|---|---|---|
| `mmdebstrap` | 在线 deb 源可直接 bootstrap | **必须在 Debian 13 builder 容器里跑**，宿主 Ubuntu 的 apt 与 mmdebstrap 差了几代，`signed-by` 解释不同，在宿主上会以 `NO_PUBKEY` 告终 |
| `selfhost` | 目标系统的 dpkg 太老，读不了宿主 dpkg 写的 status | 两阶段：`debootstrap --foreign` 只解包，导入容器后用目标系统自己的 dpkg 完成 configure。产物由脚本自己 `docker import`，不经 `import.sh` |
| `slice` | 只有 ISO，squashfs 可切 | |
| `rpmmedia` | rpm 系介质本地源 | 介质源没有签名，靠 ISO 的官方校验值兜底 |

两条 deb 路径的产物形态不同（一条落 tarball 待导入、一条直接落镜像），这个差异藏过好几个缺陷：`import.sh` 只导入第一个档位的 bug 被它掩盖了很久，因为 selfhost 那条根本不走 `import.sh`。**改任何一条路径时都要问另一条要不要同改。**

## `BK` 与 `ROOT` 不是一回事

`BK` 是 buildkit 自己的根（`lib`/`build`/`test`/`tools`/`gate` 在这里），`ROOT` 是项目根（`distros`/`out`/`localrepo`/`keys` 在这里）。submodule 布局下两者不是同一个目录，混用会在「找得到 conf 却找不到 common.sh」这种地方失败，报错离真因很远。

容器内固定把项目根挂在 `/w`，于是 buildkit 位于 `/w/buildkit`。

## 脚本纪律

**取配置只走 `tools/conf-get.sh`。** 它负责先 source `lib/arch.sh` 再 source conf。直接 source conf 会在 `ARCH` 没设时炸在 `ARCH: unbound variable`——那个报错出现在一次「探源可达性」检查里，差点让人得出「归档站从境外 runner 不可达」的结论，进而去搭自建镜像源，而实际上 curl 根本没跑起来。

**不允许「退出码 0 但没有产物」。** 每条构建路径末尾都要有出口断言。曾经有一条路径遇到不支持的 `METHOD` 时打印一句提示就 `exit 0`。

**`die` 不能用在需要重试的地方。** `die` 是 `exit`，写在取数函数里会让外层重试永远拿不到第二次机会，应该 `return 1`。改完要做变异测试确认重试真的会发生。

**重试交给 curl 自带的 `--retry` 或 `nick-fields/retry`，不要手写循环。** 手写等于把「重试几次、等多久」的策略从工具里挪到我们的代码里再实现一遍。

**卡死判定用 `--speed-limit` / `--speed-time`，不要用 `--max-time`。** 这些归档站的故障形态是「返回 200、Content-Length 正确、body 一个字节都不来」，而 `--max-time` 区分不了「慢但在进」和「卡死不动」：收紧会砍掉本来能成的大文件，放宽会让一个卡死连接白等几分钟。

**`Acquire::http::Timeout` 是不活动超时，不是总传输上限。** 曾把它从 45 改到 180，结果是构建挂了一小时。

**落地后必须校验字节非空。** 只看 curl 退出码会把「拿到空文件」当成拿到了。

## 容器与镜像

**`docker import` 要显式给 `--platform linux/$ARCH`。** 默认按守护进程的架构写 config，loong64 在 amd64 runner 上导入会被标成 amd64，而 `docker manifest create` 的平台正是取自这个字段。两条 import 路径都要给，各自带后置断言。

**给已有镜像打 label 用 `docker create` + `docker commit`，不能用 `docker build`。** BuildKit 解析 `FROM` 时要求目标平台与本地镜像一致，而发布 job 在 amd64 上还要给 arm64/loong64 打 label，它会绕开本地镜像去 registry 拉同名镜像，报 `pull access denied`。用 commit 时注意：`docker create` 不能带命令，否则 commit 会把它写成新的 `CMD`；commit 记录的是**容器**配置，docker CLI 会把 `config.json` 里的 proxies 注入成容器环境变量并一起烧进镜像。

**镜像 tag 传出构建阶段时必须带架构后缀。** 发布阶段要把同一档位的多个架构装进同一个守护进程，共用 `repo:tag` 会让 `docker load` 把 tag 从先装的身上摘走，日志里只留一句 `renaming the old one ... to empty string`。

**跨架构模拟不要引入 `tonistiigi/binfmt` 容器**，实测它会破坏本来可用的 binfmt 注册。LoongArch 用户态模拟要 QEMU 7.1 以上，Ubuntu 22.04 只带 6.2，所以相关 job 跑在 ubuntu-24.04，且要有 binfmt 前置断言。

## 门禁

发布路径上的门禁清单见 `docs/downstream-repo.md` 第六节。改本仓库时额外记住两条：

**加门禁要对门禁本身做双向变异测试。** 制造它该拦的情形确认真拦得住，制造它该放行的情形确认不误伤。有一道门禁只验了单向就上线，把九个发布 job 全卡死——判据写成了「除 Labels 外全等」，而 `docker commit` 合法地会改 `Hostname`、`Image`、`AttachStdout/Stderr`。正确写法是显式列出必须不变的语义字段。

**门禁不能只写不读。** `.gate-status` 曾经由门禁脚本写、却没有任何地方读，等于一个悬空机制，「该项不适用」这个事实从未影响过判定。新增状态文件时同步补上读取方。

## 改动之后

本仓库没有自己的 CI，验证靠下游仓库。流程是：

1. 在某个下游仓库里把 submodule 指到你的分支，本地跑通至少一个版本的一个档位
2. 推本仓库
3. 在下游同步两处 pin（submodule 与 `uses: ...@<sha>`），打印两边取到的值比对
4. 下游用 `publish=false` 跑一轮完整 CI

**同时操作两个仓库时一律用绝对路径或 `git -C`。** 靠 `cd` 建立目录上下文时，麻烦的不是报错，而是命令静默作用到错误的仓库——打印出来的 short SHA 读起来像是另一个仓库的，于是把「已同步」当成事实继续往下走。

下游改了 pin 之后**不能用 `gh run rerun --failed`**：`uses:` 的 pin 钉在调用方 commit 上，重跑会照旧用旧版脚本。

## 排错

这套东西里的缺陷大多**不在报错的地方**：静默跳过、被 `|| true` 吞掉的错误、空着传下去的变量、症状离真因三步远。

- 先在本地复现，别拿 CI 当实验台
- 看到「源不可达」「key 不对」「需要一小时」这类结论，先分清是观察还是推断。这三条都真出现过，真因分别是环境变量没传到、执行环境不对、网络偶发卡顿，照着推断改会走到自建镜像源、换 keyring、加超时上限这些完全错误的方向
- 日志里的 warning 要读。有四个 label 空了一整轮才被发现，警告当时就打在日志里
- 同一现象在两条构建路径上可能由不同原因造成，改完两边都要验
