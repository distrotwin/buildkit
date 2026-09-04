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

```
ghcr.io/distrotwin/<repo>-srcdata:<介质日期>-<架构>
例：ghcr.io/distrotwin/linx-srcdata:20230822-x86_64
```

两条规矩：

**数据镜像归属它服务的那个下游仓库**，不要集中放在 `buildkit` 名下。GHCR 的包权限是按仓库授的，放在自己仓库名下，该仓库的 workflow 用 `GITHUB_TOKEN` 天然能拉；集中放则每个下游都要额外授权一次。

**tag 用介质自己的日期，不用构建日期。** 数据镜像是介质的函数，同一个 ISO 无论切几次都该得到同一个 tag，这样重复切料是幂等的，也能一眼看出镜像对应哪份介质。厂商出新版介质才有新 tag。

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

**本机造，手工触发，不进 CI**——只有本机能取材，放进 CI 没有意义。介质不变就不需要重造。

一次性的手工配置：本机用 PAT 推的包，默认不关联任何仓库，org 内的 workflow 拉不到。推完第一次要去 package settings 里把对应的下游仓库加进访问列表（或设为 public）。**这一步漏了的症状是 runner 报 404 而不是 403**，很容易误判成「tag 写错了」。

本机那个 `gh` token 通常只有 `read:packages`／`delete:packages`，推之前需要 `gh auth refresh -s write:packages` 或另给一个 PAT。

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
