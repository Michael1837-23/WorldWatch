# build 29：实景刷新与更多点位（Claude）

日期 2026-10-31。用户反馈：实景画面很久不变、不换摄像点。

## 原因
1. App 截图循环每轮结束固定睡满一个间隔；若该轮没有城市到期（例如重启后距上次抓取不足一个间隔），下一次真正抓取被推迟到将近两倍间隔。build 27 安装后 11 分钟内实测无任何抓取。
2. 组件在城市截图超过两倍间隔时自行补抓，但只抓 1 张并覆盖 App 的 3 张；App 随后复用旧图使截图时间仍旧，再次触发组件补抓。实测修复前组件时间线为 `newyork=3 london=1 shanghai=1 hongkong=1`。
3. 诊断时发现 `NSLog` 内容在本系统统一日志中记为 `<private>`，此前无法从日志判断抓取情况。

## 修改
- 循环改为睡到最早一座城市到期（30 秒至一个间隔）。
- App 每轮记录心跳 `cameraHeartbeat`；组件仅在 App 超过两个间隔无心跳时补抓。任一轮新图不足 3 张时，用上一批其他仍可用镜头补足。
- 新增香港运输署 6 个、伦敦 TfL 7 个、洛杉矶 Caltrans 2 个、纽约 Skyline 1 个固定点位（均实测图片在数分钟内更新）。
- 实景诊断日志改用 `Logger`（`local.michael.worldwatch` / `camera`，公开字段）。
- 新增回归测试：单张新图时用上一批其他镜头补足。

## 实测（build 29 安装后）
```
17:36:51 实景轮次 london：3 张 [official:tfl-03500, official:tfl-06501, youtube:U-XyMFyX4x0]，可用来源 9/20
17:36:55 实景轮次 hongkong：3 张 [official:hktd-H106F, official:hktd-H107F, youtube:6YYmUo2TgJ0]，可用来源 7/18
17:36:56 实景时间线：newyork=3 london=3 shanghai=1 hongkong=3
17:42:05 实景轮次 london：3 张 [official:tfl-06515, official:tfl-06590, youtube:U-XyMFyX4x0]
17:42:06 实景轮次 hongkong：3 张 [official:hktd-H203F, official:hktd-H214F, youtube:6YYmUo2TgJ0]
17:42:06 实景轮次 newyork：3 张 [youtube:pv-2pVViNwc, skyline:538, skyline:6064]
```
两轮间隔约 5 分钟，镜头按最久未抓取轮换。上海仅 1 个可用来源。测试与签名构建通过。

## 扩大搜索但未采用
SkylineWebcams 东京、台北、伦敦镜头预览图停更数月至数年；台湾高速公路局仅提供 MJPEG 流且为高速公路；纽约交通局接口不可达。北京、上海、重庆仍缺少可靠公开实景源。
