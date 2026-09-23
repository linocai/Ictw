# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.2.0（Build 60）**：修复 Checker 与小说生产 SOP Review 的21项缺口，使误判可解释、检查可恢复、历史依据可信、归档局部问题不拖垮有效记忆。

## 关键决定

- 检查依据与实际写作输入一致；结论有真实来源证据，服务失败不假报正文违规；作者短稿可先检查再决定接受。
- 人物授权保持严格，但普通词命中不直接当人物出场；人物选择和豁免在程序、模型与前端一致。
- 已生成新稿可在后台单独重试检查；候选正文仍不公开，通过后才能成为当前正文。
- 正文接受独立完成；归档失败始终只影响记忆。相同记录自动去重，无法确定的状态明确标注并遮蔽旧值，有效叙事事实可按新完整契约使用；旧失败归档不自动生效。
- 历史资料缺失时说明缺什么，允许作者知情继续；恢复顺序有引导，不自动重提真书。
- 保留用户已定三句创作边界与空Bible跳过规则；不按文字顺序猜最终状态、不增加隐形模型重试。

## 当前状态

- `v2.2.0（Build 60）` 的21项 Review 修复已在本地完成；详细处置、验证和复审见 [v2.2.0施工与验收记录](archive/plans/v2.2.0-production-sop-plan.md)。
- 当前生产Backend、公开Release和本机Mac仍为 **v2.1.1（Build59）** / `e7b14b0`；Alembic head仍为 `20260830_0013`，香港旧服务停用。
- 当前施工基线为main `b342d42`；本轮未授权部署、生产迁移、真书重提或正式App换装。
- Backend 全量为305 passed、12 skipped；迁移 head 为本地 `20260923_0014`。独立 Checker、归档和中心并发/锁序复审均已收敛。
- OS27/Xcode27及双端最低27.0已现场核验，双端 Debug Build60 通过；Mac 隔离页面通过。iOS 主模拟器已安装启动，但 CUA AX 超时，未完成 iOS 页面验收；真机安装仍由用户通过Xcode执行。
- [本轮Review的21项发现](archive/operations/2026-09-23-build59-checker-sop-review.md)已逐项闭环；本版作为 main 本地提交保留，未推送或发布，不能改写 Build59 生产事实。
- 旧主Plan的长版本说明已移至上述v2.2.0记录的“从旧主Plan移入的历史版本说明”；当前状态以本页为准。

## 当前升级方向

- 保持 Build60 本地证据与生产 Build59 分离，待另获发布授权后才审计累积 delta、备份、停服迁移和发布。
- iOS 页面验收须在 Device Hub/Xcode 辅助功能连接恢复后补做；不把构建或启动当作该页面验收。

## 里程碑索引

- v2.2.0（Build60）：本地实施、验证、独立复审与资源收尾完成，未发布；[执行记录](archive/plans/v2.2.0-production-sop-plan.md)。
- v2.1.1（Build53–59）：错误可见性、空Bible、创作边界提示词和完全相同状态去重已发布；[执行记录](archive/plans/v2.1.1-error-visibility-plan.md)、[Build59发布](https://github.com/linocai/Ictw/releases/tag/v2.1.1-build59)。
- v2.1.0（Build47–52）：跨端revision、离线阅读/草稿、项目备份恢复、搜索、单书模型与Checker既有事实上下文；[完成记录](archive/plans/v2.1.0-unified-reliability-plan.md)。
- v2.0.4（Build46）：恢复重写与删除本章；[完成记录](docs/plans/v2.0.4-rewrite-and-delete-plan.md)。
- v2.0.2（Build44）：iOS交互与导出修复；[完成记录](archive/plans/v2.0.2-ios-interaction-plan.md)。
- v1.9.2（Build39）：灵感篇幅与推进边界；[完成记录](archive/plans/PROJECT_PLAN-v1.9.2-completed.md)。
- v1.8.3（Build34）：写作所有权、归档生命周期与终态事务；[完成记录](archive/plans/PROJECT_PLAN-v1.8.3-completed.md)。
- v1.8.1（Build32）：正文接受与归档分离、每章单一有效记忆来源；[完成记录](archive/plans/PROJECT_PLAN-v1.8.1-completed.md)。

## 后续 Backlog

- 本轮21项闭环前不扩展新生产能力。标签、分卷、手动排序与推送按已有产品决定移除，不作为未来项保留。
