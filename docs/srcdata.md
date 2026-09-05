# 数据镜像：厂商站对 runner 不可达时怎么接

有些系统的材料是齐的，只是放在 GitHub runner 够不着的地方。凝思与方德都属于这一类：本机秒级可达，托管 runner 135 秒超时（证据与判据见 `downstream-repo.md` 的「先确认 runner 拿得到材料」）。这一篇写怎么绕过去——在本机把材料切好，经 GHCR 中转，在 runner 上装配。

先说清适用边界：这条路**只解决网络位置问题**。材料本身不完整、签名验不了、架构造不出来（如 LoongArch 旧世界），换个位置一样做不成，别把它当万能补丁。

## 一个介质一个数据镜像

切料的单位是**介质**，不是档位。一个 ISO（或一次源快照）对应一个数据镜像，`micro`／`base`／`devel` 三档从同一个数据镜像里各取所需。

理由是三档的种子是累加的（`devel ⊇ base ⊇ micro`），所以三档种子并在一起算**一次**闭包就够，切三份是重复劳动，而且三份之间还可能因为算法漂移而不一致。分档是装配时的事，装配器（`apt` 或 `rpmmedia.py`）本来就按 include 列表挑包，给它一个大一点的池子不影响结果。

## 镜像里放什么

内容形状刻意与现有取材层的输出契约一致——**装配那一步一行都不用改**，差异全部收在取材这一层。

deb 系：

```
/src/dists/      完整索引（凝思实测 11 MB）
/src/pool/       闭包内的 .deb（凝思实测 178 MB / 254 个）
/src/.closure    闭包清单：包名 + pool 内相对路径
/src/.origin     来源锚点（见下）
/src/.epoch      SOURCE_DATE_EPOCH
```

rpm 系：

```
/src/repodata/   merged-primary.xml.gz
/src/Packages/   闭包内的 .rpm（方德 x86_64 micro 实测 96 个 / 61.5 MB）
/src/.closure /src/.closure-count /src/.epoch /src/.origin
```

**索引留完整，pool 只留闭包。** 索引才 11 MB，留全的成本可以忽略，好处是构建期 `apt` 能正常解析依赖、报错信息也正常；pool 是 4.3 GB 的主体，只留闭包压掉 24 倍。凝思整个数据镜像约 189 MB。

## 基础镜像用 scratch

数据镜像只承载数据，不承载可执行环境：

```dockerfile
FROM scratch
COPY src /src
```

取材料靠 `docker create` + `docker cp`，不需要镜像里有 shell 或 `cp`，也就没有多余的体积和攻击面。

**踩过的坑：scratch 没有 `CMD`／`ENTRYPOINT`，裸 `docker create` 报 `no command specified`。** 这个报错看起来像镜像坏了，其实给一个永不执行的命令参数就过——`create` 只建容器不跑它：

```sh
C=$(docker create "$IMG" /nonexistent)
docker cp "$C:/src" ./
docker rm "$C"
```

## 命名与 tag

所有数据镜像集中放一个 package：

```
ghcr.io/distrotwin/scratch:<介质标识>
例：ghcr.io/distrotwin/scratch:linxos-6.0.100-20230822-x86_64
```

**package 必须 public，这是算过账的，不是偷懒。** 免费档 org 的 private 包总配额只有 500 MB，还和 Actions artifacts 共享；没绑付款方式时超额是直接阻断而不是计费。一份凝思介质就约 189 MB，配额必超。public 的存储与流量在官方文档里明写免费。集中放一个 public package 也顺便消掉了「private 包要逐仓库授访问权」那个易错环节 —— 漏授的症状是 runner 报 404 而不是 403，很容易误判成 tag 写错。

**tag 用介质自己的标识（ISO 文件名去扩展名，或源快照日期），不用构建日期。** 数据镜像是介质的函数，同一个 ISO 无论切几次都该得到同一个 tag，这样重复切料是幂等的，也能一眼看出镜像对应哪份介质。厂商出新版介质才有新 tag。

## 完整性锚：数据镜像不是权威来源

这是整条路最要紧的一处。材料经过了本机这一跳，所以必须能追溯回厂商发布的锚点，否则「镜像等于公开归档」这句话就不成立了。

`.origin` 记来源，且必须与 `distros/*.conf` 里钉的值逐字一致：

| 系统 | 锚点 | 强度 |
|---|---|---|
| 凝思 | ISO 的官方 `md5` + `sha256` + 字节数 | 厂商发布的校验和，可验 |
| 方德 | repo base + `repomd revision` + `sm3sum.txt` 的 sha256 | 只防传输损坏，**不防替换** |

装配前必须校验 `.origin` 与 conf 一致，不一致就中止。少了这道门禁，数据镜像被换掉不会被任何检查发现。

方德那个弱锚点要如实写进 README：它的包有签名但公钥拿不到（详见 `downstream-repo.md`），所以只能用校验和清单兜，那和签名不是一回事。

## 谁造、什么时候造

**切料在本机，首次发布走 workflow 转推。** 只有本机能取材，切料（算闭包、下载、验 SHA256、生成 `.origin`/`.manifest`）都在本机做；但 **package 的第一次创建必须由 workflow 用 `GITHUB_TOKEN` 推**——GHCR 包的可见性没有 API，本机 PAT 首推的包落成 internal（计费等同 private，占 500 MB 免费配额且超额阻断），而 workflow 首推的包继承仓库可见性，public 仓库推出来就是 public（实测判据：`probe-pkg-visibility` 读回 `visibility: public`）。流程：本机把切好的目录打成 `src/` 前缀的 tar.zst 传 release asset → 触发 `srcdata-publish.yml`（导入、验 manifest 指纹、推送、断言可见性 public）→ 删中转 release。

package 已是 public 之后，追加新 tag 可以直接用本机 `tools/srcdata-make.sh`（打包、推送、拉回验 manifest、打印要钉进 conf 的指纹），本机 token 需要 `write:packages`。runner 侧取材对应 `tools/srcdata-fetch.sh`（拉取、两道 manifest 门禁、展示 `.origin`）。

## runner 侧怎么接

**不新增 `METHOD`。** 数据镜像替代的是「取材」这一层，而不是一条新的构建路径。在取材前面加一个前置步骤：conf 里给了 `SRCDATA_IMAGE` 就从数据镜像取，没给就走原有逻辑（挂 ISO 或连远程源）。

```
conf 有 SRCDATA_IMAGE
  → docker pull / create / cp 到 $MEDIA
  → 校验 .origin 与 conf 钉的值一致
  → 之后完全走原有 selfhost / rpmmedia 逻辑
```

这样 `METHOD=selfhost` 的凝思、`METHOD=mmdebstrap` 的方德，都只是多了一行 conf，装配、测试、发布三段一个字都不用改。

## 实测数据

| 环节 | 实测 |
|---|---|
| 凝思介质切片 | 4.3 GB → 254 包 / 178 MB（压 24 倍），零缺失 |
| 方德 x86_64 micro 闭包 | 9460+4547 包的源 → 96 包 / 61.5 MB |
| 上传 58 MB 到 GitHub | 12 秒 |
| runner 取回 58 MB | 2.1 秒（27.4 MiB/s） |
| 推 GHCR 数据镜像 | 7.9 秒 |
| 拉回并 `docker cp` 取出 | 1.5 秒 |
| 往返一致性 | 96 个包聚合 sha256 两侧完全相同 |

按比例，189 MB 的凝思数据镜像推约 25 秒、拉约 5 秒——对构建总时长可以忽略。

链路本身由 `.github/workflows/probe-srcdata.yml` 验证，判据落在逐字节一致上，不落在「命令没报错」上。

## 闭包既是切料工具，也是材料完整性的检验

算闭包时如果冒出一堆 unresolved，说明这份材料本身不自洽——那就算全量搬过来也拼不出能跑的系统。所以闭包该在接一个新系统的早期就算一次，它比「先建一轮看看」便宜得多。

deb 侧算闭包要注意两件事，都会让结果偏小到不可用：

**`Priority: required` 必须并进种子。** `debootstrap` 阶段一装的就是这一批（凝思有 73 个），漏了它闭包看着能算完，装出来的 rootfs 起不来。

**or 依赖（`a | b`）不能只看第一个候选。** 介质里可能只带了第二个，只认第一个会误判成缺失。要在候选里挑第一个真的在索引里的。

## 接凝思与方德时踩过的坑（都会在别的厂商身上重演）

**厂商 dpkg 的 IMA 标签在 rootless 容器里必炸。** 方德的 dpkg 给 maintainer script 设 `security.ima` xattr，rootless docker 里 setxattr 直接 `Operation not permitted`，报错文案是吓人的 `internal error: set ima label failed! core dumped`。rootful（CI runner 的 sudo / --privileged 容器）没这个问题。所以这类系统的本机预演要么用宿主 sudo，要么接受只有 CI 能验。

**厂商会自造依赖环。** 方德给 libcrypt1 加了 libssl1.1 依赖，形成 `libssl1.1→debconf→perl-base→libcrypt1` 的环：apt 的 immediate-configure 拆不开（关掉 `APT::Immediate-Configure` 也一样，换个报错而已），dpkg 能拆。症状是 mmdebstrap 报 `Could not configure 'libssl1.1'`，看着像包坏了。判据：mmdebstrap 系（debmedia）走不通的厂商，换 selfhost（debootstrap 两阶段）再试一次，别直接判死。

**厂商 maintainer script 会假定文件已存在。** 方德 apt 的 postinst 直接 `sed /etc/apt/apt.conf`，裸自举时没有这个文件 → exit 2。selfhost 的 `STAGE1_TOUCH` 就是为这类假定准备的：stage2 之前把 conf 列出的路径预置为空文件。

**厂商的 suite 代号会踩 debootstrap 的年代分支。** 方德把 codename 叫 `base`，不在 debootstrap 的 buster/bullseye 白名单里，被当成 bookworm+ 而强求 `usr-is-merged` 包（bullseye 没有这个包）。介质是我们生成的，把代号改记成对应的 Debian 代号即可，改名依据写进 `.origin`。

**厂商的 dpkg 钩子会挂死构建。** 凝思的 `linx-noroot-conf` 装 `exec-after-dpkg.sh`（三权分立管理），容器里这些钩子 13 分钟不退出、dpkg 变僵尸。`PIN_NEVER` 从 debootstrap 入口拦，不要事后 purge（会弄坏依赖图）。

**`Priority: required` 是厂商可乱标的档位。** 方德把 425 MB 的 360 浏览器标成 required。所以 deb-closure 默认种 `Essential:yes`（mmdebstrap 装的就是它），debootstrap 类流程用 `--with-required` 显式打开并配 `PIN_NEVER` 拦垃圾。

**GHCR package 的可见性没有 API。** REST 与 GraphQL 都改不了，只能网页操作（package settings → Danger Zone）。所以 srcdata 取材步先 `docker login`：public 时无害，internal/private 时是唯一可用路径。计费上 internal 等同 private（占 500 MB 免费配额），转 public 前多推几份介质就会顶满。
