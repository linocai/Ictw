# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.2.0（Build 61）**：修复实际生成故障并完成SOP畅通性复审，使记忆选择、人物检查与连续失败恢复能够正确衔接。

## 关键决定

- 检查依据与实际写作输入一致；结论有真实来源证据，服务失败不假报正文违规；作者短稿可先检查再决定接受。
- 人物授权保持严格，但普通词命中不直接当人物出场；人物选择和豁免在程序、模型与前端一致。
- 已生成新稿可在后台单独重试检查；候选正文仍不公开，通过后才能成为当前正文。
- 正文接受独立完成；归档失败始终只影响记忆。相同记录自动去重，无法确定的状态明确标注并遮蔽旧值，有效叙事事实可按新完整契约使用；旧失败归档不自动生效。
- 历史资料缺失时说明缺什么，允许作者知情继续；恢复顺序有引导，不自动重提真书。
- 保留用户已定三句创作边界与空Bible跳过规则；不按文字顺序猜最终状态、不增加隐形模型重试。

## 当前状态

- **v2.2.0（Build61）已于2026-09-24完成一条龙发布**：源码标签、生产Backend、公开Release和本机Mac均为 `a8a38dd`，生产Alembic head仍为 `20260923_0014`；[本轮Review与发布证据](archive/operations/2026-09-24-build61-sop-flow-review.md)。
- 昨晚生成故障与SOP畅通性Review确认的11项问题全部修复，独立复查通过。记忆选择、人物检查、连续重试恢复及具体失败原因显示已衔接。
- 发布覆盖实际Build60 `b620558` 至Build61全部改动；68个线上文件校验一致，停服备份、恢复演练、无变更迁移及内外网门禁通过，业务数据与密钥保持不变。
- Backend 322 passed、12项旧协议 skipped；客户端Store/HTTP 38项及状态测试通过。双端OS27 Release签名构建与严格验签通过。
- Mac已换装并打开成稿、现有草稿编辑及失败原因页面。iOS保持Build61的Xcode安装状态，未导出IPA；最终真机页面验收仍未完成，设备支持审计pending为空。
- 上线后完整性、外键、单实例与鉴权健康通过，无在途任务、无新增warning。保留历史失败记录，未自动生成、接受、重提或补选人物。
- 交付物与回退备份已保留；本轮本地、远端临时资源已按校验清单清理，详细证据见发布记录。

## 后续升级方向

- 补做iOS最终页面验收；用户通过Xcode完成真机安装。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。

## 里程碑索引

- v2.2.0（Build61）：生成协议与SOP恢复11项修复已发布，Backend更新及Mac换装完成；[Review与发布记录](archive/operations/2026-09-24-build61-sop-flow-review.md)、[Release](https://github.com/linocai/Ictw/releases/tag/v2.2.0-build61)。
- v2.2.0（Build60）：Checker与生产SOP修复已发布，Backend迁移及Mac换装完成；[执行记录](archive/plans/v2.2.0-production-sop-plan.md)、[Release](https://github.com/linocai/Ictw/releases/tag/v2.2.0-build60)。
- v2.1.1（Build53–59）：错误可见性、空Bible、创作边界提示词和完全相同状态去重已发布；[执行记录](archive/plans/v2.1.1-error-visibility-plan.md)、[Build59发布](https://github.com/linocai/Ictw/releases/tag/v2.1.1-build59)。
- v2.1.0（Build47–52）：跨端revision、离线阅读/草稿、项目备份恢复、搜索、单书模型与Checker既有事实上下文；[完成记录](archive/plans/v2.1.0-unified-reliability-plan.md)。
- v2.0.4（Build46）：恢复重写与删除本章；[完成记录](docs/plans/v2.0.4-rewrite-and-delete-plan.md)。
- v2.0.2（Build44）：iOS交互与导出修复；[完成记录](archive/plans/v2.0.2-ios-interaction-plan.md)。
- v1.9.2（Build39）：灵感篇幅与推进边界；[完成记录](archive/plans/PROJECT_PLAN-v1.9.2-completed.md)。
- v1.8.3（Build34）：写作所有权、归档生命周期与终态事务；[完成记录](archive/plans/PROJECT_PLAN-v1.8.3-completed.md)。
- v1.8.1（Build32）：正文接受与归档分离、每章单一有效记忆来源；[完成记录](archive/plans/PROJECT_PLAN-v1.8.1-completed.md)。

## 后续 Backlog

- 标签、分卷、手动排序与推送按已有产品决定移除，不作为未来项保留。
