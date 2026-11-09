# 任务：2.9 —— 热点引擎（把「一篇报道」升级成「一个事件」）

你在已有的 macOS 原生项目里工作。App 界面文字用简体中文，代码风格与现有文件一致：注释少而精，命名简洁，**不引入任何第三方包**。

## 0. 项目与必读文件

- **项目位置**：根目录 `/Users/michael/Documents/ChatGPT/Monitor world`，`main` 分支，远端为私有 GitHub 仓库。**只在本地提交，不要 push**；完成后由审核者验收再推送。
- **环境**：macOS 26、Apple Silicon、`/Applications/Xcode.app`、Swift 5 语言模式、团队 `R58LB5VQ4A`。构建用 `zsh build.command`，测试用 `zsh test.command`。
- **新增文件**：新增一个 `Sources/Stories.swift`，放事件模型与纯函数算法。
  - 把它加进 `test.command`。
  - 手工登记到 `WorldWatch.xcodeproj/project.pbxproj` 的 App 与 Widget 两个 target，参考 `Sources/MapLayers.swift` 的登记方式。
  - 除此之外尽量改现有文件，不再新建文件。
- **先读**：
  - `docs/evaluation/热点聚类评测.md`：**本任务的依据**。参数都来自这份评测，不要自行改动。
  - 参考实现（评测工具，不属于 App，不要编进 App 工程，只能照着写）：
    - `Tools/cluster-eval/main.swift`：`manualAliases`、`Gazetteer`、`stripBoilerplate`、`chineseBigrams`、`englishWords`、`stopwords`、`namedEntities`。
    - `Tools/cluster-eval/Evaluation.swift`：`unitVector`、`centroidOnline`、`hotness`。
  - 夹具：`Tests/Fixtures/cluster-eval/` 下的 `corpus.json`、`gold.txt`、`pair-labels.tsv`。
  - `Sources/Feed.swift`：
    - `WorldEvent`；
    - `NewsDisplayMode`（目前 `latest`、`rotation` 两种）；
    - `NewsSnapshot`，其中 `conflictSignals` 字段就是「另存的轻量数据不占 100 条名额」的先例；
    - `uniqueNewsEvents`、`latestEvents`、`displayPool`、`digestPool`、`widgetTimeline`、`refreshedSnapshot`、`limitedSourceFeeds`、`retainedNewsLimit`。
  - `Sources/Main.swift`：
    - `EventStore.refresh()`：每个来源抓回后、裁剪到 100 条**之前**就更新 `observedConflicts`，新索引照此办理；
    - `publishWidgetSnapshot`；
    - `WorldView.scopes` 与 `rows`、范围菜单、`SettingsView` 的「小组件」分组。
  - `Sources/TitleTranslation.swift`：`TitleTranslator` 里 `TranslationSession(installedSource:target:)` 的直接用法。
  - `Widget/WorldWatchWidget.swift`：`WorldWatchProvider.load()`、`WorldComponentProvider.entries`、新闻行视图。

### ⚠️ 必须遵守的已知约束
1. **时间线体积**：不增加任何组件的时间线条目数，不把事件索引塞进 `TimelineEntry` 或共享摘要。2.5 版曾因时间线约 11 MB 被拒收，组件只剩灰色占位。
2. **build 号**：必须升，否则 WidgetKit 会沿用缓存的旧组件。不改任何组件的 kind 名称。
3. **算法只在 App 里跑**：组件只读 App 算好的结果，App 没运行时退回现有行为，见第 4.4 节。
4. **不用本机语义向量**：不要用 `NLEmbedding`、`NLContextualEmbedding` 或训练出的权重。评测证明它们没有增益。可以用 `NLTagger` 识别人名、地名、机构名。
5. **结果可复现**：同一输入两次运行，结果必须完全相同。
   - 字典遍历要先排序再求和或比较。
   - 平分时用确定的次序打破（时间，再 id）。

## 1. 功能定义

1. **事件聚类**：最近 72 小时内的所有已抓取新闻（不受 100 条上限）按评测推荐的算法合并成「事件」。一个事件 = 多家媒体对同一件事的报道。
2. **热度**：按**不同媒体**计数。
   - `bbc*`、`guardian*`、`cns*` 各算一家，其他来源一个 id 算一家；灾害来源（USGS、GDACS）不参与。
   - ≥2 家时显示「N 家」，≥3 家进入热点排序。
3. **新的组件显示模式「热点优先」**：与「最新优先」「综合轮播」并列；「最新优先」仍是默认。
4. **App 新增「热点」范围**。
5. **同一事件只占一格**：「最新」及各领域范围，以及最新优先、综合轮播两种组件模式中，同一事件的多篇报道只保留一行。
6. **突发标记**。
7. **🆕「自上次查看以来」标记**：只在 App 里显示。
8. **「飙升」实体**：只在 App 的热点范围显示。

## 2. 算法（`Sources/Stories.swift`，与参考实现同口径）

### 2.1 事件索引
- **存储**：App 维护一个最近 72 小时的轻量索引，存在 `~/Library/Application Support/WorldWatch/story-index.json`。组件不读它。
- **每条记录存**：
  - 新闻 id、来源 id、发布时间 `date`、App 首次见到的时间 `observedAt`、链接；
  - 中文文本：中文来源用原标题，英文来源用译文 `translatedTitle`，没有译文时为空；
  - 英文文本：英文来源用原标题，中文来源用回译，没有回译时为空。
- **何时写入**：在 `refresh()` 里每个来源抓回、裁剪前写入，与 `observedConflicts` 同处。
  - 译文或回译稍后才到时，更新对应记录的文本。
  - 停止抓取的来源，其记录不参与聚类。
  - 超过 72 小时的记录（按 `date`，没有 `date` 的按 `observedAt`）删除。
  - 索引上限 2000 条，超出时删最旧的。
- **去重先行**：完全相同的标题或规范链接视为同一条，沿用 `canonicalNewsURL`，标题规范化同参考实现的 `normalizedTitle`。

### 2.2 回译（中文标题 → 英文）
- **直接调用**：用 `TranslationSession(installedSource: zh-Hans, target: en)`，不经过 SwiftUI。繁体先用 `StringTransform("Traditional-Simplified")` 转简体。
- **前提**：只在 `LanguageAvailability().status(from: zh-Hans, to: en) == .installed` 时做，否则跳过，不提示、不联网，算法照常运行。
- **批量**：每轮最多 20 条。
- **缓存**：存 `~/Library/Application Support/WorldWatch/back-translations.json`，随索引一起清理，键为原标题。
- **不用在线备用**：回译不走 Google 公共接口。

### 2.3 特征
照抄参考实现，不要「顺手改进」：
- **去格式词**：先用 `stripBoilerplate` 去掉栏目前缀和格式词。
- **中文字二元组**：取自中文文本；跳过两个都是数字的二元组，以及纯 ASCII 字母二元组。
- **英文单词**：取自英文文本，用 `enumerateSubstrings(byWords)`；至少 3 个字符，去停用词、纯数字和 `'s`；长度大于 4 且以 s 结尾（非 ss）的去掉末尾 s。
- **向量**：两类词合成一个稀疏向量，键加前缀 `z`、`e` 区分。权重为 IDF = ln(N / df)，N 与 df 按**当前索引中参与聚类的条目**计算。再做 L2 归一化。
- **国家**：用 `Gazetteer` 规则，即 `Locale.Region.isoRegions` 的 en、zh-Hans、zh-Hant 名称加 `manualAliases`，在原标题和中文文本上匹配。
- **人名、机构、地名**：用 `NLTagger(.nameType, joinNames)` 分别在中文文本（`.simplifiedChinese`）和英文文本（`.english`）上识别，转小写。

### 2.4 单遍聚类
- **处理顺序**：按发布时间从早到晚逐条处理；没有时间的排最后，平分按 id。
- **打分**：每条与每个现有事件计算 `cos(条目向量, 事件中心)`。事件中心是成员向量之和。
  - **实体加分**：条目与事件共享 IDF ≥2.0 的国家，或 IDF ≥2.5 的人名，加 0.10。
  - **时间减分**：条目时间晚于事件最后一条成员超过 36 小时，减 0.10。
- **归属**：取得分最高的事件；得分 ≥ **0.28** 就并入，否则新建事件。
- **全量重算**：每次索引变化后对整个索引重算，在后台执行，不阻塞主线程，合并间隔约 1 秒，与现有增量摘要同步。
  - 性能要求：Apple Silicon 上 2000 条以内全量重算 < 1 秒。
- **事件 id**：取最早成员的新闻 id，便于列表动画保持身份。
- **代表标题**：
  - 热点模式和事件详情里，用与中心余弦最高的成员；若有中文来源成员，且它与最高者相差 ≤0.05，用中文来源。
  - 最新、领域范围里那一行显示**最新的成员**，保证时间和标题一致。

### 2.5 热度、突发、飙升
- **事件热度**（只算有发布时间的成员；联合国新闻这类「只有日期」的来源计入媒体数，但不参与时间计算）：
  ```
  heat = outlets × 0.5^(距最后一篇的小时数 / 6) + 最近 2 小时新增的媒体数
  ```
  按 heat 从高到低排；平分时按最后一篇时间、再按 id。
- **突发**：满足任一条件，突发标记持续到判定时刻后 3 小时。
  - 某事件第 3 家媒体的首篇发布时间，与第 1 家首篇相差 ≤60 分钟，且第 1 家首篇在 6 小时内；
  - USGS M7.0 及以上、GDACS 红色预警，且发生在 6 小时内。
- **飙升实体**：
  - 统计范围：国家与人名两类实体（不展示二元组碎片）。
  - 条件：最近 6 小时出现的不同媒体数 ≥3，且是此前 66 小时平均每 6 小时的 3 倍以上（此前为 0 时按 0.5 计）。
  - 展示：取前 5 个，国家用中文名，人名用中文文本里识别出的写法。

## 3. 数据与共享

- **共享摘要新字段**：`NewsSnapshot` 加可选字段 `stories: [NewsStory]?`，只放媒体数 ≥2 的事件，最多 40 个，按 heat 排序。
- **`NewsStory` 字段**（`Codable`、`Sendable`、`Equatable`）：
  - `id`、`memberIDs`、`outlets`（来源显示名，去重后有序）、`heat`；
  - `representativeID`、`latestID`、`firstDate`、`lastDate`；
  - `breakingUntil: Date?`。
- **体积**：先估算加入后 `widget-snapshot.json` 的体积，汇报里给出前后大小。
- **改动检测**：`stories` 变化时视为组件内容变化，走现有的 15 秒优先重载逻辑。只是 heat 数值变化而排序不变时，不触发重载。
- **新模式**：`NewsDisplayMode` 加 `hot`，标题「热点优先」，旧偏好和旧缓存默认仍为 `latest`。
  - 全仓库检查 `== .latest`、`== .rotation`、`mode ==`，以及「最新／综合」字符串映射，逐处决定 `hot` 的行为。
  - 原则：`hot` 和 `latest` 一样只生成当前列表，不安排轮播。

## 4. 界面

### 4.1 App 列表
- **「N 家」标识**：新闻行来源后面加小号次要色「· N 家」；≥3 家用橙色。
  - 点它弹出原生 `popover`，列出该事件全部成员：来源、时间、标题（译文优先，悬停看原文），每行可点开原报道。
  - 这是最小版的事件页，不做时间线和分组。
- **突发**：标题前加红色小字「突发」，不用卡片或横幅。
- **🆕**：
  - App 记录上次查看时间：主窗口隐藏或关闭时，以及 App 退出时，存进 `UserDefaults.standard`。
  - `observedAt` 晚于上次查看时间的事件，行首显示一个小蓝点。
  - 首次使用（没有记录）时不显示。
- **「热点」范围**：放在 `scopes` 的最前面。
  - 列表顺序：先放媒体数 ≥3 的事件，再放 2 家的，都按 heat 排；然后接单家新闻，按时间倒序。
  - 列表上方一行小字「飙升：巴拉圭 · 米勒 · …」，没有飙升实体时不显示。
- **其他范围**：「最新」和各领域范围中，同一事件只保留最新成员那一行，并带「N 家」。
  - 「综合」范围同样折叠。
  - 顺序：过滤 → 现有去重 → 事件折叠 → 国内占比 → 截取条数。
- **新闻过滤**：「N 家」统计事件全部成员，不受新闻过滤影响；代表行本身仍须通过过滤。

### 4.2 设置
- 「小组件」分组的显示模式分段控件增加第三项「热点优先」。
- 选中时 App 范围跳到「热点」，与现有模式联动一致。
- footer 加一句：「热点按报道同一事件的媒体数排序，由 App 计算；App 未运行时组件按最新优先显示。」

### 4.3 组件
- **热点优先**：
  - 列表顺序与 App「热点」范围相同。
  - 来源行显示「BBC、半岛等 5 家」，宽度不够时只显示「5 家」。
  - 突发事件标题前加红色「突发」。
- **最新优先、综合轮播**：同一事件折叠成一行，来源行末尾加「· N 家」。
- **世界总览新闻列**：沿用当前模式的同一规则。
- 不显示 🆕 和飙升。

### 4.4 降级
- 组件使用 `snapshot.stories` 的条件：存在，且 `snapshot.updatedAt` 在 2 小时内。
- 否则热点优先按最新优先显示，不加「N 家」，不显示任何提示。
- 组件自己抓取新闻时不做聚类。

## 5. 测试（扩展 `Tests/FeedCheck.swift`，默认不联网）

1. **夹具验收**：从 `Tests/Fixtures/cluster-eval/` 读入语料和金标，用**生产代码**聚类。其中 `zh`、`en` 字段分别当作译文和回译。在 FeedCheck 里写一个小评分器，按以下口径断言：
   - 媒体数 ≥3 的事件中，含误合并的个数 = 0。误合并定义同评测：同组里有一对既不在同一 E、也不同属一个 G、也未在 pair-labels 中标为 S 或 R。
   - 媒体数被虚报的事件个数 = 0。
   - 15 个媒体数 ≥3 的金标事件，平均媒体找回率 ≥0.70。
   - 658 个去重后的条目，合并成 ≤560 个事件。
   - 同一输入运行两次，结果完全一致。
   - 2000 条（夹具复制并改 id 构造）全量聚类耗时 < 1 秒。
   - 与参考工具的差异：用 `zsh Tools/cluster-eval/cluster-eval.command hotness` 在 t=0.28 跑出的「媒体找回率 0.75、故事 544 个」作对照，生产实现应在 ±0.02 和 ±5 以内。
2. **特征单元测试**：
   - 栏目前缀去除；
   - 纯数字二元组和纯数字单词不计；
   - 「US」大写才匹配美国，「us」不匹配；
   - 繁体「巴拉圭總統」与简体能识别同一国家；
   - 共享国家加分、36 小时减分的边界。
3. **热度与突发**：
   - 用构造数据验证 heat 公式与排序；
   - 3 家媒体 60 分钟内报道触发突发，61 分钟不触发，3 小时后标记消失；
   - 灾害来源不计入媒体数；
   - BBC 两个栏目算一家。
4. **列表与模式**：
   - 「最新」范围折叠后同一事件只出现一次，且显示最新成员；
   - 「热点」范围顺序正确；
   - 新闻过滤下「N 家」不变；
   - `NewsDisplayMode` 旧值兼容，`hot` 往返编码；
   - 组件在 `stories` 缺失或超过 2 小时时退回最新优先；
   - 共享摘要体积有上限断言（`stories` ≤40）。
5. **索引**：72 小时过期、2000 条上限、停止抓取的来源被排除、译文晚到时更新文本、去重。
6. 现有所有用例保持通过。

## 6. 版本、构建、安装、验收

1. **版本号**：
   - 两个 Info.plist 的 `CFBundleShortVersionString` 改为 `2.9`，`CFBundleVersion` 改为 `32`。
   - 同步：WidgetBundle 启动日志；`Sources/Feed.swift` 与 `Sources/MapLayers.swift` 的 User-Agent 改为 `WorldWatch/2.9`；README 的版本号。
2. **测试与构建**：`zsh test.command` 通过；`zsh build.command` 成功，且没有新增警告。
3. **安装**：
   1. 退出 App。
   2. 把 `~/Applications/世界动态.app` 移到 `.build/installed-before-build32.<随机>` 备份。
   3. `ditto dist/世界动态.app ~/Applications/世界动态.app`。
   4. `codesign --verify --deep --strict` 通过。
   5. `lsregister -f` 登记安装版。
   6. 结束组件进程后启动 App。
4. **系统日志**：确认组件时间线被接收，zsh 里写全路径 `/usr/bin/log`：
   ```bash
   /usr/bin/log show --last 5m --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "WorldWatch"' | grep -E "succeeded with|too large"
   ```
   必须看到 `succeeded with`，且没有 `too large timeline archive`。
5. **实测**：App 运行至少 15 分钟后记录：
   - 索引条数、事件总数、≥2 家与 ≥3 家的事件数；
   - 热点范围前 10 个事件的代表标题与媒体数；
   - 是否出现突发与飙升；
   - 一次全量重算耗时，用 `Logger` 输出（subsystem `local.michael.worldwatch`，category `stories`，公开）。
   
   人工抽查前 10 个事件：有误合并的逐条写进验收记录。最后**把组件模式恢复为「最新优先」**。
6. **预览图**：用 `NSHostingView` 或 `ImageRenderer` 导出以下画面，深色、浅色各一张，存到 `.build/acceptance-2.9/`：
   - App「热点」范围；
   - 「N 家」popover；
   - 热点优先模式的大号新闻组件。
7. **文档**：
   - 更新 `README.md`、`世界动态-产品与交互设计说明.md`、`CHANGELOG.md`；
   - 新建 `docs/acceptance/升级验收记录-2.9.md`；
   - 把本文件移到 `docs/codex-tasks/2.9-热点引擎.md`。
   - 只写已实现、已实测的内容。
8. **提交**：本地提交（中文提交信息，不加任何 AI 署名行），**不要 push**。

## 7. 交付汇报

- 改动文件清单与作用。
- 夹具验收的各项数字，与参考工具的对照。
- 共享摘要加入 `stories` 前后的体积。
- 第 6 节第 5 步的实测记录与抽查结论。
- 测试、构建输出的最后几行；`chronod` 日志结果；预览图路径。
- 没验证到的部分要明确写出，尤其是组件端实际显示和动画。
