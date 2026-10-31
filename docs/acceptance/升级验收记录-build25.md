# build 25：持续冲突底图验收

2026-10-31，本地版本 2.8 / build 25。用户选择「持续存在的冲突地区」，新增独立月度基线，保留新闻叠加。仅本地提交，不 push。

## 改动文件与作用

| 文件 | 作用 |
| --- | --- |
| `Sources/MapLayers.swift` | UCDP 官方索引、月度 CSV 解析、发生地国家汇总、每日检查、失败缓存与离线基线 |
| `Sources/WorldMap.swift` | 合并月度与新闻四档显色、15 国上限、热点标签、Russia 备用锚点、亚丁与乌克兰标题定位补充 |
| `Sources/WorldComponents.swift` | 热点名称引线与背景、无障碍说明 |
| `Sources/Main.swift` | 持续冲突图层说明、数据月份、来源许可与刷新后更新设置 |
| `Widget/WorldWatchWidget.swift` | 正式 provider 加载共享／离线月度基线，组件不下载 CSV；更新说明和构建日志 |
| `Config/AppInfo.plist`、`Widget/Info.plist` | 构建号 25；组件 kind 保持不变 |
| `Tests/FeedCheck.swift` | CSV／月份／归属／离线／过期／15 国回归与实测诊断 |
| `README.md`、`世界动态-产品与交互设计说明.md` | 数据语义、来源、轻量缓存和已验证边界 |

## 来源与语义

[UCDP 官方下载页](https://ucdp.uu.se/downloads/index.html) 当前最新月度数据为 **2026 年 9 月 / 26.0.9**；来源 CSV 为 [GEDEvent_v26_0_9.csv](https://ucdp.uu.se/downloads/candidateged/GEDEvent_v26_0_9.csv)。Hegre、Croicu、Eck、Högbladh（2020），*Introducing the UCDP Candidate Events Dataset*，CC BY 4.0；[官方代码本](https://ucdp.uu.se/downloads/candidateged/ucdp-candidate-codebook1.5.pdf)。本应用有筛选、聚合与分级变更。

原始下载 1,611,352 字节，SHA-256：`20256b0d674f4c58d747c7c75ddc012eabfedf44ada22f436ef2d9a6405567d5`。没有把原始事件 CSV 保存进 App Group 或时间线。

筛选：`Clear`、`active_year` 为真、暴力类型 1–3、`best > 0`、日期完全位于来源月份内；去重后聚合 29 个国家／地图单元。Gaza Strip／West Bank 按事件行政位置归到 PSE，不按参战方染色。这里包含国家间、非国家组织间及针对平民的有组织暴力，不能把它理解为正式战争名单。

应用自定义的月度死亡估计四档阈值为 1／25／250／1000，与新闻评分四档取较大值；最终按档位、月度死亡估计、新闻评分选至多 15 国。实际为 UKR 4、YEM 4、PAK 3、SOM／ETH／MMR／SDN／PSE／MEX／NGA／MLI／COD／LBN／RUS 2、BFA 1。俄罗斯与乌克兰在本次数据下均显色。Mexico 的记录属于数据源的非国家有组织暴力，非因被新闻提及而染色。

每天检查索引，发布新月份时才下载 CSV。离线使用核对过的随包汇总，失败保留来源月份；月份结束超过 120 天则暂停底图并在设置标明过期。整国填色只是国家级活动提示，不能代表全国战区，也不能代替实时战线或全部持续冲突清单；15 国上限也会省略排序靠后的地区。

## 验证

- `zsh test.command` 通过，原有新闻、来源、台风、ISS、偏好测试继续通过；新增 CSV 引号／换行／BOM、重复记录、损坏数据、月份过滤、地点归属、无新新闻仍显色和 120 天过期覆盖。
- 使用正式 `WorldComponentProvider.entries` 与实际共享摘要实测：全部领域被排除、新闻结果为空时，地图仍与全部新闻模式相同，10 条时间线均保留俄乌基线，国家数均不超过 15。测试规则仅在临时 CLI 内存中使用，没有改用户设置。
- 通过实际 Swift 网络层检查官方索引并读取真实源月度汇总；ISS 轨道 19 点，活跃红／橙台风 0 个。没有虚构台风图标。
- `zsh build.command` 成功，只有原有已签名二进制不剥离警告，无新增警告。签名严格验证通过。
- 已备份并安装至 `~/Applications/世界动态.app`，实际退出旧的「世界动态」进程后启动安装版；安装版主程序与 dist SHA-256 一致。备份：`/Users/michael/Documents/ChatGPT/Monitor world/.build/installed-before-build25.q5ACPQ`。
- 安装后 App Group 的 `ongoing-conflicts.json` 为 **1531 字节**、29 国、版本 26.0.9；新闻缓存总数 **100 条**。用户新闻过滤、城市顺序和地图偏好与安装前一致，LSUIElement 继续开启。
- `chronod-final.log` 确认总览 `succeeded with 10 entries`，本次日志窗口没有 `too large timeline archive`。
- 正式地图 Canvas 导出紧凑／大尺寸、深／浅色预览，检查俄乌显色、主要国家和 Africa 标签、标签避让、空间站轨道；布局扫描结果 `[]`。

测试最后三行：

```text
PASS: Africa 标签、最近空间站轨道、覆盖期补刷及五分钟失败重试
PASS: UCDP 月份选择、CSV 引号/换行/BOM/去重、有效记录与发生地、俄乌离线基线、新闻叠加、120 天过期及 15 国上限
PASS: 2.7 地震时限与震级标签、GDACS类型和结束时间、台风过滤/名称/乱序历史预测/60点上限、冲突评分/48小时/四级/15国/词边界、夏令时、天气数组及过期、ISS插值及经线断线、偏好迁移与过期缓存
```

构建输出：

```text
warning: not stripping binary because it is signed: /Users/michael/Documents/ChatGPT/Monitor world/.build/NativeSigned/Build/Products/Release/WorldWatchWidget.appex/Contents/MacOS/WorldWatchWidget (in target 'WorldWatch' from project 'WorldWatch')
已生成开发签名版本：/Users/michael/Documents/ChatGPT/Monitor world/dist/世界动态.app
```

系统最后一次记录：

```text
2026-10-31 00:25:05.747 Df chronod[72730:a7a547] [com.apple.chrono:timeline.store] [local.michael.worldwatch::local.michael.worldwatch.widget:WorldWatchDashboard:systemExtraLargeLandscape::704.00/344.00/27.88:(null)~(null)] on local reload: succeeded with 10 entries
```

证据目录 `.build/hotspot-coverage-25/`：`test.log`、`build.log`、`live-map.log`、`integration.log`、`chronod-final.log`、`compact-dark.png`、`compact-light.png`、`large-dark.png`、`large-light.png`、`ucdp-summary.json`。

## 未验证部分

未直接目测桌面 Widget 最终画面、未完整操作新设置分组；预览与系统接收时间线分别验证。尚未发生下个月数据发布，自动跨月更新的真实发布场景未实测，解析与月份选择已离线覆盖。没有长时间休眠或连续数月运行实测。没有调整用户已有过滤规则、城市、桌面组件位置或任何系统组件外观偏好。根目录未跟踪的 CODEX_TASK 文档保持原样、不纳入提交。

## build 26：审核修正（Claude）

审核复跑测试与签名构建均通过；`chronod` 过去 12 小时接收总览时间线 237 次，无超限。发现 build 23「精简新闻缓存」引入的问题：所有来源合计只保留最新 100 条时，USGS 地震与 GDACS 预警的发生时间较早，被全部挤出，安装版缓存中两者均为 0 条，地图地震／灾害图层与 App「灾害」范围恒为空。已改为两类灾害来源不计入 100 条上限；新增回归测试。安装 build 26 后缓存为 USGS 2 条、GDACS 4 条、新闻 100 条，`chronod` 确认总览 `succeeded with 10 entries`。
