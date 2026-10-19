# go-x86-to-graviton Skill 使用说明

这是一个 [Agent Skill](https://agentskills.io)，用来驱动 AI 编程 agent 把 Go 应用从 x86 迁移到 AWS Graviton（ARM64/aarch64）：静态分析、只做必要的修改、最后在真实 arm64 硬件上验证。

它按官方 [AWS Graviton Agent Skills](https://aws.github.io/graviton/tools/skills/) 的结构编写——官方目录里有 Java、Python、.NET 三个 skill，**没有 Go**。

> 这份文档是完整的操作手册。只想快速上手看[最短路径](#最短路径)；想理解它为什么这么设计，从[为什么 Go 不能照抄 Java 的做法](#为什么-go-不能照抄-java-的做法)开始读。

---

## 目录

- [为什么 Go 不能照抄 Java 的做法](#为什么-go-不能照抄-java-的做法)
- [最短路径](#最短路径)
- [安装](#安装)
- [运行前准备](#运行前准备)
- [skill-config.md（可选但强烈建议）](#skill-configmd可选但强烈建议)
- [怎么跟 agent 说](#怎么跟-agent-说)
- [三个阶段分别在做什么](#三个阶段分别在做什么)
- [输出怎么读](#输出怎么读)
- [独立使用两个脚本](#独立使用两个脚本)
- [常见失败与对应处理](#常见失败与对应处理)
- [这个 skill 刻意不做的事](#这个-skill-刻意不做的事)
- [已验证与未验证](#已验证与未验证)
- [和 Arm MCP Server / AWS Transform 的关系](#和-arm-mcp-server--aws-transform-的关系)

---

## 为什么 Go 不能照抄 Java 的做法

**Go 的依赖没有「架构维度」这回事。**

Java 和 Python 的 Graviton skill，大部分精力花在一个**产物可用性**问题上：这个依赖有没有 `linux-aarch_64` classifier、有没有对应解释器的 `aarch64` wheel。Go 里这个问题不成立——Go 依赖是源码，`go.mod` 记版本、`go.sum` 记源码哈希，两者都与架构无关。**绝大多数真实迁移中，这两个文件前后完全一字不差。**

把 Java/Python 的套路搬到 Go 上，产出的只会是噪音：一份满是「为了 ARM64 兼容性升级了 23 个依赖」的报告，而真正必要的两三行改动被埋在里面。这个 skill 的开头第一节就是专门防这件事的，范围护栏文档把它列为首要失效模式。

真正会出问题的，按阻塞频率排序：

| # | 类别 | 原因 | 何时暴露 |
|---|---|---|---|
| 1 | **cgo** | `import "C"` 让构建依赖 aarch64 的 C 工具链和每个被链接 C 库的 aarch64 构建 | 构建期，报错明确 |
| 2 | **只有 amd64 的 build constraint 和汇编** | 存在 `//go:build amd64` 文件或 `_amd64.s`，但没有 arm64 或通用兜底 | 构建期——或者兜底是个 stub 时，**静默丢功能** |
| 3 | **非 Go 产物** | 提交进仓库的 `.so`/`.a`、URL 里写死 `_amd64` 的下载、没有 arm64 manifest 的基础镜像、Makefile 里的 `GOAMD64` | 构建期或容器启动期 |
| 4 | **行为差异** | arm64 弱内存序暴露出的数据竞争、FMA 融合后的浮点结果、直接写的 `syscall.SYS_*` 号、硬编码页大小、`CGO_ENABLED` 改动带来的 DNS 解析变化 | **运行期，在生产，间歇性** |

第 4 类是「宣布迁移成功之后」才爆的。一个纯 Go 程序两秒就交叉编译完，照样可能在 Graviton 上死锁而在 x86 上永远不出现——因为 x86-64 是 Total Store Order，arm64 是弱序。有数据竞争的程序在两个架构上都是未定义行为，但只有 arm64 会稳定地让你看见。

准确的说法不是「arm64 把并发代码搞坏了」，而是：

> **arm64 把 x86 藏起来的竞争暴露出来了。缺陷一直在，迁移只是你发现它的时刻。**

**实测数据。** 同一子网同一可用区两台 EC2，除架构外配置完全一致（`c7g.2xlarge` vs
`c7i.2xlarge`，都是 Amazon Linux 2023、Go 1.27.2、8 vCPU）。消息传递 litmus：写者先写
`data` 再写 `flag`，读者先读 `flag` 再读 `data`，无任何同步，两个变量**放在不同 cache line**：

| | arm64 (Graviton3) | x86-64 |
|---|---|---|
| 采样 | 80.8M / 75.5M / 87.8M | 407.8M / 404.3M / 403.6M |
| 读者看到 flag 领先 data | **18,049,284 / 28,576,401 / 30,639,002** | **0 / 0 / 0** |
| 比率 | **22.3% / 37.9% / 34.9%** | **12 亿次采样中 0 次** |

代码在 [`tests/memory-model/main.go`](../tests/memory-model/main.go)。两个方法学错误是踩
出来的，都写进了文件注释：相邻的 `int64` 全局变量落在**同一条 cache line** 上，缓存一致性
协议就免费保证了顺序——第一版因此在 arm64 上测出 **1.9 亿次采样 0 违例**，是个假的 null；
另外访问必须走 `//go:noinline` 辅助函数，否则 Go 编译器可以假定程序无竞争、把全局变量
整个循环留在寄存器里，根本没有东西可重排。

**这个测量同时推翻了一条我原先的论断。** 竞争**检测器是架构无关的**：同一个真实形状的缺陷
（用一个普通 `bool` 发布懒加载缓存，见 [`tests/memory-model/cache/`](../tests/memory-model/cache/)），
普通 `go test` 在**两台机器上都通过**，`go test -race` 在**两台上都报 3 条 DATA RACE**。
检测器是 happens-before 插桩，不是硬件探针。所以在 x86 上、甚至在模拟器里跑 `-race`
**并不更弱**——skill 早期版本说"模拟器不算"是错的。arm64 额外带来的是不同的调度交织，以及
上表那个 22–38% 的真实发生率。

这个表述在运维上很重要。认为「Graviton 弄坏了我们服务」的团队会回滚；理解「Graviton 暴露了一个存在两年的竞争」的团队会去修。

所以 **`go test -race ./...` 跑在真实 arm64 硬件上**，是这个 skill 里单项价值最高的检查，是强制退出条件之一，而且 Java 和 Python 的 Graviton skill 里都没有对应项。

---

## 最短路径

```bash
# 1. 装 skill（Claude Code 示例；其他平台见下一节）
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git /tmp/gs && \
  mkdir -p ~/.claude/skills/go-x86-to-graviton && \
  cp -r /tmp/gs/{SKILL.md,POWER.md,summaries.md,phases,document_references,scripts} \
        ~/.claude/skills/go-x86-to-graviton/ && rm -rf /tmp/gs

# 2. 先用只读脚本扫一眼，判断这次迁移的量级
/tmp/gs/scripts/go_arch_scan.sh /path/to/your/project
```

然后在你的项目目录里对 agent 说：

```
用 go-x86-to-graviton skill 把这个 Go 服务迁到 AWS Graviton。
验证环境：graviton-ci 这台 c7g.xlarge，Amazon Linux 2023。
```

**第一句话里说明 arm64 验证环境，比其他任何信息都重要。** 不说明的话，退出条件 2 和 8–13 全部会是 `NOT RUN`，等于迁移没验证就发了。

---

## 安装

skill 放在**仓库根目录**，所以仓库地址本身就是 skill 地址。

### Kiro

打开 **Agent Steering & Skills** 面板 → **+** → **Import a skill** → **GitHub**，粘贴：

```
https://github.com/RadiumGu/go-x86-to-graviton-skill
```

Kiro 读的是 `POWER.md`。

### Cursor

**Settings**（`Cmd+Shift+J` / `Ctrl+Shift+J`）→ **Rules** → **Add Rule** → **Remote Rule (GitHub)**，粘贴同一个地址。

### Claude Code

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git \
    /tmp/go-graviton-skill && \
  mkdir -p ~/.claude/skills/go-x86-to-graviton && \
  cp -r /tmp/go-graviton-skill/{SKILL.md,POWER.md,summaries.md,phases,document_references,scripts} \
        ~/.claude/skills/go-x86-to-graviton/ && \
  rm -rf /tmp/go-graviton-skill
```

### 其他平台

拷贝动作完全一样，只换目标目录：

| 平台 | 目标目录 |
|---|---|
| GitHub Copilot / VS Code | `.github/skills/go-x86-to-graviton/`（项目级） |
| OpenAI Codex | `~/.codex/skills/go-x86-to-graviton/` |
| Windsurf | `.windsurf/skills/go-x86-to-graviton/`（项目级） |
| Goose | `~/.config/goose/skills/go-x86-to-graviton/` |
| Roo Code | `.roo/skills/go-x86-to-graviton/`（项目级） |
| **任意兼容平台** | `.agents/skills/go-x86-to-graviton/`（项目级，跨平台标准路径） |

`.agents/skills/` 是 Agent Skills 规范的跨平台标准路径，所有兼容平台都会读。

### 验证装没装上

对 agent 说一句就能确认：

```
列出 go-x86-to-graviton skill 的四类失效分类。
```

答得出 cgo / build constraint / 非 Go 产物 / 行为差异这四类，就是读到了。

---

## 运行前准备

| 需要什么 | 没有会怎样 |
|---|---|
| **Go 工具链**（项目的那个版本） | 分析降级成纯 grep 模式，**所有结论都是 `CHECK` 而不是 `PASS`**。脚本会明确告诉你它在降级模式 |
| **arm64 环境**：Graviton EC2 / Apple Silicon / GitHub `ubuntu-24.04-arm` runner / arm64 容器 | 只有「交叉编译能过」这一条结论。**交叉编译不执行任何代码**，第 1 类（带 cgo）和第 4 类对它完全不可见 |
| **容器运行时** | 镜像平台检查和容器内产物扫描变成 `CHECK` |
| **C 编译器** | cgo 项目无法原生构建；**而且纯 Go 项目也跑不了 `go test -race`**——竞争检测器需要 cgo |
| **git** | 每一步都提交，所以每个改动可以单独 revert；没有 git 就失去这个能力 |

### 关于「交叉编译」和「模拟器」的两条硬限制

这两条在 skill 里反复强调，因为它们是最容易被当成「已验证」的两种假象：

**交叉编译不执行任何东西。** `GOOS=linux GOARCH=arm64 go build ./...` 在 x86 笔记本上通过，是真实且有价值的信号——对纯 Go 项目来说构建风险基本就清掉了——但它只满足退出条件 1，不满足其他任何一条。

**模拟不等于竞争检查。** x86 主机上用 `docker run --platform linux/arm64` 跑 arm64 容器，QEMU 确实在执行 arm64 指令，但它**不会忠实复现 arm64 的内存序**：QEMU 用户态模拟会以真实硬件不会的方式串行化，所以真机能暴露的竞争在模拟下可能一直看不到。模拟适合做构建、链接、启动和容器检查，**不能作为退出条件 9 的证据**。

没有真机时正确的做法是：退出条件 9 记 `NOT RUN`，并把它作为未关闭的风险写进总结——而不是写 `PASS`。

---

## skill-config.md（可选但强烈建议）

在**你的项目根目录**（不是 skill 目录）放一个 `skill-config.md`，告诉 agent 几件它猜不出来的事。从 [`document_references/skill-config.template.md`](../document_references/skill-config.template.md) 拷一份，删掉用不上的。

四个字段对结果影响最大：

```yaml
language:
  go:
    # 1. 真正发布用的构建命令。`go build ./...` 通常只是开发用的那条路，
    #    `go build ./...` 过了而 `make release` 挂掉，不算通过。
    build_command: make release

    # 2. 部署实际传的 build tags。不给这个，整个 build constraint 分析
    #    分析的是一个不会发布的构建组合，结论无效。
    build_tags: 'netgo,osusergo'

    # 3. 部署实际用的 CGO_ENABLED。决定 Phase 3 构建什么，也决定
    #    `-race` 能不能编出来。
    cgo_enabled: 0

    # 4. 可用的 arm64 环境。这个字段决定这个 skill 有多少部分真能跑起来。
    arm64_environment: 'c7g.xlarge / Amazon Linux 2023，SSH 名 graviton-ci'
```

配置只控制**怎么做**，不能扩大范围：

- `agent-scope-boundaries.md` 始终生效，没有任何字段能允许「顺手升级依赖」「顺手修 CVE」「顺手重构」
- 声明的 Go 版本只能通过 `go.toolchain_bump` 改，而且只在「升级是通往 arm64 构建的唯一路径」时
- **任何字段都不能豁免退出条件**，包括 arm64 上的 race 检查
- 实测到的事实优先于配置的事实：配了 `build_system: make` 但没有 Makefile，以实测为准并把差异记进报告

完整字段表在 [`document_references/skill-configuration.md`](../document_references/skill-configuration.md)。

---

## 怎么跟 agent 说

### 一次完整迁移

```
用 go-x86-to-graviton skill 把这个 Go 服务迁到 Graviton。

验证环境：graviton-ci（c7g.xlarge / Amazon Linux 2023），可以 SSH。
发布路径是 make release（走 goreleaser），不是 go build。
部署是 ECS Fargate，运行镜像 amazonlinux:2023。
CGO_ENABLED=0，build tags 是 netgo,osusergo。
```

### 只要评估不要改代码

```
用 go-x86-to-graviton skill 只跑 Phase 1，不要做任何修改。
我要知道这次迁移的工作量和有没有 blocker。
```

Phase 1 全程只读，只写 `graviton-validation/`，适合先摸清量级再决定要不要做。

### 批量评估多个仓库

```
对 ~/repos 下每个 Go 仓库跑 go-x86-to-graviton skill 的 Phase 1，
然后汇总成一张表：仓库名、是否用 cgo、Shape C 数量、go.mod 是否需要改、预估工作量。
```

跑之前先用脚本过一遍会快得多——`go_arch_scan.sh` 一个仓库几秒钟，可以先把「零发现」的仓库筛掉。

### 只查某一类问题

```
用 go-x86-to-graviton skill 的 behavioral-differences 参考文档，
只检查这个仓库的数据竞争风险，并在 graviton-ci 上跑 go test -race -count=10。
```

### 怀疑已经在 Graviton 上出问题了

```
这个服务在 Graviton 上偶发返回过期缓存，x86 上从来没有。
按 go-x86-to-graviton skill 的 Phase 3.2 在 graviton-ci 上跑 race 检测。
```

这是这个 skill 设计时最想覆盖的场景。间歇性的错误结果，在 Graviton 上出现而 x86 上不出现，**在被证伪之前都应当按数据竞争处理**——不要去调超时、加重试、改 `GOGC`。

---

## 三个阶段分别在做什么

### Phase 1 — 静态分析（只读）

1. **1.1 工程结构**：识别所有构建系统并确定**哪一个才是发布路径**；module / workspace / vendor 布局；Go 版本及它的四个互相矛盾的来源（`go.mod`、`toolchain`、Dockerfile builder 镜像、CI setup-go——通常**镜像那个才是真的**）；目标 OS、glibc 还是 musl、内核页大小；然后做两趟 `go list` 捕获。

   两趟捕获的原因是实测出来的：`go list -deps -json ./...` 只能看到**被 import 到的**包。对一个没人 import 的 amd64-only 目录，`go list ./...`、`go list -deps -json ./...`、`go build ./...` 和 `go vet ./...` **全部报告零错误**；只有显式点名那个目录才会报 `build constraints exclude all Go files`。所以第一趟查「现在就阻塞构建的」，第二趟逐目录扫「一旦有人 import 就阻塞的」。

   捕获必须带 `CGO_ENABLED=1`。这也是实测的：cgo 关掉时 `go list` 把 cgo 文件放进 `IgnoredGoFiles` 而 `CgoFiles` 为空，于是一个重度使用 cgo 的项目看起来是纯 Go 的。而 `go env CGO_ENABLED` 在任何没装 C 编译器的机器上都是 `0`。

2. **1.2 cgo 清点**：每个用 cgo 的包，它链接的每个 C 库，以及每个库**以哪条路线进入构建**——这一步分错了后面全错：

   | 路线 | 怎么识别 | arm64 问题是什么 |
   |---|---|---|
   | 模块内自带 C 源码 | 模块里有 `.c`/`.h` | **没有可用性问题**，C 源码按编译器目标编译。缺的是编译器不是移植 |
   | 系统库 `-lfoo` / `pkg-config` | `LDFLAGS=[-lfoo]` | 目标发行版的 aarch64 仓库里有没有这个包 |
   | 模块内自带预编译归档 | 提交进去的 `.a`/`.so`，常见 `*_linux_amd64.a` | **这个版本**的归档里有没有 arm64 那份。**与版本强相关** |
   | 构建时下载 | Makefile / `go:generate` / Dockerfile 里的 `curl` | 下载 URL 有没有 arm64 变体 |

   第三条是**唯一**让「升级依赖」成为正当修复的路线，因为 arm64 归档的存在性是具体版本的属性。

3. **1.3 build constraint 与汇编**：每个按架构门控的文件，**包括 `vendor/` 里的**（amd64-only 汇编真正藏身的地方就是那里），分成三种形态：

   | 形态 | 样子 | 结论 |
   |---|---|---|
   | A：amd64 和 arm64 都有 | `hash_amd64.s` + `hash_arm64.s` | **没问题**。要明确写「没问题」，否则后面的人会来「修」它 |
   | B：amd64 快路径 + 通用兜底 | `x_amd64.go` + `//go:build !amd64` 的 `x_generic.go` | 能构建，可能慢。**不要改**，记一条基准测试备注就行 |
   | C：只有 amd64，没兜底 | 只有 `x_amd64.go` | **blocker**。Phase 2.2 修 |

   形态 B 有个更阴的变种：兜底不是「慢一点的正确实现」，而是 `return 0`、`return error` 或 `panic("unsupported architecture")`。这种能通过构建、能通过 `go vet`，如果测试文件也被 amd64 门控住了还能通过测试——**在 Graviton 上返回错误数据的绿色迁移**，是这一类里最坏的结果。所以必须读兜底的函数体，不能看名字。

4. **1.4 非 Go 产物与构建配置**：按**内容**（`file`，不是文件名）判断提交进来的二进制；脚本/Dockerfile/CI 下载的工具；从 registry 查每个镜像的平台；`GOAMD64`、写死的 `GOARCH=amd64`、`-march`；GoReleaser 的 `goarch` 列表；以及所有**选了 x86 的部署描述符——包括因为「没写」而默认 x86 的**。

   最后这点很容易漏：Lambda 不写 `Architectures` 默认 `x86_64`，ECS 不写 `runtimePlatform.cpuArchitecture` 默认 `X86_64`。「没找到问题」必须是「检查了没写的情况」而不是「只检查了写错的情况」。

5. **1.5 行为差异扫描**：竞争风险的先验（有没有裸 goroutine、手搓同步、CI 有没有跑过 `-race`）、x86 CPU 特性门控、直接写的 syscall 号和数字型 seccomp 过滤器、硬编码 4096、断言浮点精确相等的测试、`CGO_ENABLED` 当前值。

6. **1.6 Go 版本**：只记录不修改。唯一真正阻塞退出条件的版本下限是 Go 1.14（`linux/arm64` 的竞争检测器支持），现实中没有项目低于它。**在受支持版本上建议升 Go 就是超范围。**

### Phase 2 — 修复

每一处修改都必须能追溯到 Phase 1 的某条具名发现。追溯不到的就删掉。

- **2.1 cgo**：`#cgo` 指令按架构拆分（`#cgo amd64 CFLAGS: -msse4.2` / `#cgo arm64 CFLAGS: -march=armv8-a+crypto`），**拆分不是删除**，x86 的优化要留着；aarch64 系统包先查目标发行版索引再改（查索引的命令都在宿主自身架构上跑，不用模拟，几秒钟）；自带归档的升到最低那个带 arm64 的版本并引用归档文件名作证据；真没有 aarch64 构建的库写成「用户决策 + 三个选项 + 各自代价」，不要自作主张替换
- **2.2 build constraint**：优先放宽门控（但注意**文件名后缀会覆盖 `//go:build` 行**——只改注释不改文件名，构建会一模一样地失败，这是修这类问题最常见的无效操作）；其次加通用实现；blocker 在依赖里时优先升级依赖，**绝不手改 `vendor/`**（下一次 `go mod vendor` 会静默还原，改动从构建里消失且不报错）
- **2.3 非 Go 产物**：下载 URL 改成从 `$TARGETARCH` 或 `uname -m` 推导，**而且要有显式失败分支**——静默落回 `amd64` 的 `case` 正是 x86 二进制进 arm64 镜像的途径
- **2.4 构建配置**：核心是 Dockerfile 的交叉编译多阶段模式，这是 Go 相对 Java/Python 的**结构性优势**：

  ```dockerfile
  # builder 在构建机的原生架构上跑...
  FROM --platform=$BUILDPLATFORM golang:1.24 AS build
  ARG TARGETOS
  ARG TARGETARCH
  # ...交叉编译出目标架构的二进制。不用 QEMU，全速。
  RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
      go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

  # runtime 阶段不要写 --platform，它必须是目标架构
  FROM gcr.io/distroless/static:nonroot
  COPY --from=build /out/app /app
  ```

  三条规则，每条被违反都是一个发现：`--platform=$BUILDPLATFORM` **只能**在 builder 阶段（不加的话 buildx 会用 QEMU 模拟整个构建，40 秒变 20 分钟）；runtime 阶段**必须没有** `--platform`；**`GOARCH=${TARGETARCH}` 才是让二进制变成 arm64 的那一行**——只设 `--platform` 不设 `GOARCH`，你得到的是一个 arm64 镜像里装着 amd64 二进制，manifest 检查能过，运行时 `exec format error`

- **2.5 行为修复**：竞争用同步原语修。**明确的禁止清单**：`time.Sleep`、`runtime.Gosched()`、改 channel 缓冲、调换语句顺序、`GOMAXPROCS=1`、调 `GOGC`、加重试、给检测报告打 `//nolint`——这些都只是让竞争更难被观测到，缺陷还在程序里，而且比之前更糟，因为现在有人以为它修好了
- **2.6 运行时建议**：只写文档**不应用**，每条带证据等级（A = 源自仓库或官方文档，构造上正确；B = 需要在目标上实测后再采纳；N/A = 查过了不适用——写 N/A 和写建议一样有价值，它说明这个问题被问过了）

### Phase 3 — arm64 验证

1. **3.0 环境**：选环境并明确**它能证明什么**（见上面那张表）；Go 工具链对齐，只在当前会话内切换，不动机器默认值
2. **3.1 构建与 vet**：交叉编译 → 原生构建（带部署实际的 `CGO_ENABLED`）→ **部署自己的发布命令**（这一步最常被跳过，也最该跑）；每个失败打一个标签：`INFRA`（环境问题，不阻塞）/ `ARM64`（真架构问题，阻塞）/ `PRE-EXISTING`（迁移前就坏，不阻塞）。**x86 基线不是可选的**——没有同 commit 的 x86 对照，`ARM64` 和 `PRE-EXISTING` 分不开，报告的核心论断就没有依据
3. **3.2 测试与竞争**：两次独立运行、两份独立日志、两条独立退出条件。`-race` 改变时序、内存布局和构建标志，所以带 `-race` 的运行不能替代普通运行，普通运行也不是条件 9 的证据
4. **3.3 容器**：构建 arm64 镜像，然后**把镜像文件系统导出来，在宿主上扫描里面每一个原生文件**（这样扫描本身不经过模拟）。`scratch`/`distroless-static` 镜像应该只有一个 ELF；`distroless/base` 或 alpine 镜像里就是那个下载来的 x86 `grpc_health_probe` 现形的地方
5. **3.4 启动**：`runtime.GOARCH` 必须是 `arm64`；cgo 开启时 `ldd` 每个库都要解析到 aarch64 文件；真实请求打一个

---

## 输出怎么读

全部写在你项目的 `graviton-validation/` 下。

```
graviton-validation/
├── 00-summary.md                              ← 先读这个
├── 01-project-assessment.md
├── 02-cgo-report.md
├── 03-build-constraint-report.md
├── 04-artifact-and-build-config-findings.md
├── 05-behavioral-findings.md
├── 06-runtime-configuration.md                ← 建议，一条都没应用
├── 07-build-test-results.md
└── raw/                                       ← 原始工具输出，逐字保留
```

`00-summary.md` 的三条规则，也是你 review 时该盯的三件事：

1. **每条退出条件都有结论 + 它在哪个环境跑的。** `PASS (Graviton c7g.xlarge, AL2023)` 和 `PASS (cross-compiled on x86)` 是两个不同的事实，条件 2 和 8–13 不能由后者满足
2. **`NOT RUN` 是合法结论，不是失败。** 给没跑的检查写 `PASS` 才是失败——而且是这套文档里唯一不可挽回的错误
3. **开头先说第 4 类发现。** 构建过了没过，看条件表就知道；需要人来决策的是一份竞争报告或一次 `CGO_ENABLED` 行为变更

review 代码改动时，重点看两件事：

- **`go.mod` 的 diff 有几行。** 超过三行且每行追溯不到 `02`/`03` 里的具名发现，就是范围跑偏——这是这个 skill 被误用的最常见方式
- **「刻意没改」那一节有没有写。** 写了，说明「没改」是结论；没写，说明可能是漏了

---

## 独立使用两个脚本

两个脚本都只用 bash 和 coreutils，兼容 bash 3.2，不装 agent 也能单独用。

### `go_arch_scan.sh` — 只读静态扫描

覆盖 Phase 1 里可确定的部分。**不在被扫描的目录里写任何东西**，也不跑项目的构建。

```bash
# 直接看
./scripts/go_arch_scan.sh /path/to/project

# 存成 Phase 1 的原始输出
./scripts/go_arch_scan.sh . > graviton-validation/raw/go-arch-scan.txt
```

退出码：`0` 干净，`1` 有发现，`2` 不是 Go 项目。输出每行前缀 `OK` / `CHECK` / `FINDING`——**`CHECK` 是线索不是结论**，写 `PASS` 之前必须逐条消掉。

没有 Go 工具链时它降级成 grep 模式，所有结论都是 `CHECK`，并在开头明确说明自己在降级模式。有工具链时它用 `go list` 作事实基础，并跑完两趟 Shape C 检测。

批量预筛：

```bash
for d in ~/repos/*/; do
  [ -f "$d/go.mod" ] || continue
  printf '%-40s ' "$(basename "$d")"
  ./scripts/go_arch_scan.sh "$d" >/dev/null 2>&1 && echo "clean" || echo "has findings"
done
```

### `arm64_validate.sh` — Phase 3 矩阵

跑交叉编译、原生构建、`go vet` 对照、`go test`、`go test -race`、二进制架构检查，把每份日志按报告引用的规范文件名写到 `graviton-validation/raw/` 下。

```bash
./scripts/arm64_validate.sh . \
  --cgo 1 \
  --tags 'netgo,osusergo' \
  --count 5 \
  --skip 'TestPostgres|TestS3' \
  --build-cmd 'make release'
```

它会判断自己是不是在 arm64 硬件上，**凡是测不了的检查一律报 `NOT RUN` 而不是 `PASS`**——包括 race 那条，它拒绝在模拟环境下认为该条件满足。

发现竞争时它会额外跑一遍 x86 基线，因为这个对照决定了这个发现该怎么表述：

- x86 上也报竞争 → 这个项目只是从来没跑过 `-race`
- 只有 arm64 报 → 弱内存序才是让它可观测的原因

### `sync_power.sh`

改完 `SKILL.md` 后跑一下，从它重新生成 `POWER.md`，保证两个入口不会漂移。

---

## 常见失败与对应处理

### 构建期

| 报错 | 真实原因 | 在哪修 |
|---|---|---|
| `imports X: build constraints exclude all Go files in <dir>` | Shape C，通过 import 可达。报错里的 import 链就是定位 | Phase 2.2 |
| `unrecognized instruction "MOVQ"` + `asm: assembly of x.s failed` | 一个没有架构约束的 `.s` 文件里装着 x86 指令，被编译到了 arm64 | Phase 2.2 |
| `undefined: <符号>`，而该符号定义在 `_amd64.go` 里 | 伪装的 Shape C：通用兜底文件少声明了东西 | Phase 2.2 |
| `unrecognized command line option '-msse4.2'` | x86-only 的 flag 传给了 aarch64 的 C 编译器 | Phase 2.1 |
| `cannot find -lfoo` / `pkg-config: exit status 1` | 目标环境没装那个库的 aarch64 包 | Phase 2.1 路线 2 |
| `file format not recognized`（来自 `ld`） | 一个 x86-64 的 `.a`/`.o` 被链进 arm64 二进制 | Phase 2.3 |
| `undefined: syscall.SYS_OPEN` | arm64 上不存在这个 syscall 常量。**这是好结果**——编译期报错，有文件有行号 | Phase 2.5 |
| `exec format error`（构建过程中执行某个工具时） | arm64 builder 里装了 x86 的工具 | Phase 2.3 |
| `C compiler "gcc" not found` | cgo 开着但 builder 镜像没编译器（`golang:*-alpine` 默认没有） | Phase 2.1 路线 1 |
| `-race requires cgo` | `CGO_ENABLED=0` 或没有 C 编译器，竞争检测器编不出来 | 为 race 这一次单独开 cgo 编测试二进制 |

前三条是在一个故意写坏的 fixture 上、`go1.27.2 linux/arm64` 实际跑出来抓下来的原文，不是转述。

### 运行期

| 现象 | 含义 | **不是** |
|---|---|---|
| `exec format error` | 二进制或 entrypoint 架构不对 | 权限问题 |
| `SIGILL: illegal instruction` | arm64 上执行了 x86 指令，通常来自汇编路径或一个 `GOAMD64` 二进制 | Go runtime 的 bug |
| `SIGBUS: bus error` | 非对齐访问，arm64 对某些指令形式比 x86 严格 | 内存耗尽 |
| `/lib/ld-musl-aarch64.so.1: not found` | glibc 链接的二进制放进了 alpine（musl）镜像 | 缺库 |
| DNS 解析行为变了 | `CGO_ENABLED` 被改过，`net` 换了解析器 | arm64 的差异 |
| **偶发返回错误结果，或偶发卡住** | **数据竞争。回 3.2 跑 race 检测** | 「还需要调参」 |

最后一行是最该记住的。在 Graviton 上出现而 x86 上不出现的间歇性正确性问题，**在被证伪之前都是数据竞争**，竞争检测器就是证伪手段。不要去调参、加重试、加超时。

### 流程层面

| 症状 | 说明 |
|---|---|
| `go.mod` diff 有二十几行，理由写「为了 ARM64 兼容性」 | 范围跑偏。Go 依赖没有架构维度，这些升级一个都不是发现 |
| 报告里有 200 行 `COMPATIBLE` 的传递依赖表 | 这不是严谨，是把 Python skill 的形状搬到了没有信息量的地方，还把真正的四条发现埋了 |
| 某个检查写了 `PASS`，但旁边注着「交叉编译」 | 交叉编译只满足条件 1。其余应为 `NOT RUN` |
| 竞争报告被写成 `PASS` 加一句说明 | 竞争是阻塞项。要么修，要么条件 9 不通过并作为用户决策 |
| `vendor/` 被手改了 | 下一次 `go mod vendor` 会静默还原。改法是升级依赖、`replace`、或用依赖自带的 purego 类 tag |
| 建议被应用了 | `06-runtime-configuration.md` 里的东西一条都不该应用，`GOARM64` 尤其不该 |

---

## 这个 skill 刻意不做的事

- 为任何「不是具名 arm64 blocker」的理由升级依赖
- 改 Go 版本（除非升级是通往 arm64 构建的**唯一**路径，且配置允许）
- 改基础镜像家族（alpine ↔ debian ↔ distroless），除非当前家族**完全没有** arm64 镜像
- 跑 linter、`gofmt`、`goimports`，或做任何重构
- 修 CVE（真实且紧急，但属于另一个改动；混进来会让迁移 diff 无法 review，还把安全修复绑在架构决策上）
- 应用任何运行时建议，包括 `GOARM64`
- 自作主张把可用的 cgo 依赖换成纯 Go 实现（换 `mattn/go-sqlite3` 为 `modernc.org/sqlite` 常常是好主意，但它换掉的是 SQL 引擎实现、性能特征和失效模式——这是用户决策）
- 给只在交叉编译或模拟下跑过的检查写 `PASS`

发现了但超范围的东西，会单独列在 `00-summary.md` 的「Observed, out of scope」一节，一行一条，不做修改。

---

## 已验证与未验证

**已验证**（在故意写坏的 Go fixture 上，`go1.27.2 linux/arm64` 真机）：

- 两趟 Shape C 检测，包括那个实测结论：对未被 import 的 amd64-only 包，`go list ./...`、`go list -deps -json ./...`、`go build ./...`、`go vet ./...` **四条命令全部报零错误**，只有显式点名目录才报
- `go list` 只在 `CGO_ENABLED=1` 时填充 `CgoFiles`；关掉时同一批文件出现在 `IgnoredGoFiles` 里，于是 cgo 项目看起来是纯 Go
- 标准库过滤（否则 `runtime/cgo` 会出现在每一份 cgo 清点里）
- `#cgo` 的 x86 flag 检测，`// #cgo` 和块注释两种写法都覆盖
- 无约束 `.s` 文件的检测，以及它产生的真实构建报错原文
- 扫描脚本的三个退出码，分别在坏 fixture、干净项目、非 Go 目录上
- `arm64_validate.sh` 在 arm64 硬件上端到端跑通，包括「没有 C 编译器时把 race 条件报成 `NOT RUN` 而不是 `PASS`」这个分支

**未验证**：竞争检测器的「真的抓到竞争」那条分支（当前主机没有 C 编译器，没能产出真实的 `WARNING: DATA RACE`）；cgo 路线 2/3/4 的解析命令对真实发行版索引和 module cache 的执行；容器和部署描述符相关路径。这些来自 Go 与 AWS 的规范文档和工具链自身行为，不是实际跑出来的。

**整个 skill 不断言任何依赖的版本下限。** 凭记忆写的下限是一个等着发生的错误结论，所以文档给的是「该跑哪条命令去查」，而不是「某版本起支持 arm64」。

---

## 和 Arm MCP Server / AWS Transform 的关系

三者是互补的，不是替代：

| 工具 | 是什么 | 对 Go 的覆盖 |
|---|---|---|
| **这个 skill** | 给 AI agent 的操作规程，Go 专用，带证据标准和退出条件 | 完整，包含弱内存序这类 Go 特有的第 4 类问题 |
| [**Arm MCP Server**](https://github.com/arm/mcp) | MCP server，提供 arm64 相关的扫描工具（基于 migrate-ease）、容器架构检查、Arm 知识库检索、LLVM-MCA 汇编分析 | 扫描层**明确支持 Go**。语言无关的通用能力，可以和这个 skill 同时挂上 |
| [**Porting Advisor for Graviton**](https://github.com/aws/porting-advisor-for-graviton) | AWS 官方的确定性静态扫描，**非 AI** | 官方支持 Go 1.11+。适合做 CI 门禁，以及对 agent 结论做交叉验证 |
| **AWS Transform custom (ATX)** | AWS 的托管转换服务 | 托管转换只有 `AWS/early-access-java-x86-to-graviton`（Java）。Go 需要自建 custom transformation |

建议的组合：Arm MCP Server 挂到 agent 上提供扫描工具，这个 skill 提供流程和判据，Porting Advisor 做一次独立交叉验证——**不要让 agent 的判断成为唯一证据**。
