# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.2.0（Build 63，后端已部署）**：加强Writer前置写作指导，在作者Bible的核心剧情与明确边界内充分展开过程。

## 关键决定

- 检查依据与实际写作输入一致；结论有真实来源证据，服务失败不假报正文违规；作者短稿可先检查再决定接受。
- 人物授权保持严格，但普通词命中不直接当人物出场；人物选择和豁免在程序、模型与前端一致。
- 已生成新稿可在后台单独重试检查；候选正文仍不公开，通过后才能成为当前正文。
- 正文接受独立完成；归档失败始终只影响记忆。相同记录自动去重，无法确定的状态明确标注并遮蔽旧值，有效叙事事实可按新完整契约使用；旧失败归档不自动生效。
- 历史资料缺失时说明缺什么，允许作者知情继续；恢复顺序有引导，不自动重提真书。
- 保留用户已定三句创作边界与空Bible跳过规则；不按文字顺序猜最终状态、不增加隐形模型重试。

## 当前状态

- **Build63后端提示词更新已部署**：`465138a`，线上Writer固定规则核验一致；19项相关测试、备份恢复与生产健康门禁通过。客户端和公开安装包仍Build62，无需换装即可使用新提示词；[部署证据](archive/operations/2026-09-24-build63-deployment.json)。
- **v2.2.0（Build62）于2026-09-24完成一条龙发布**：客户端源码标签、公开Release和已安装Mac为 `6c8d209`，生产Alembic head仍为 `20260923_0014`；[修复与发布记录](archive/operations/2026-09-24-build61-sop-flow-review.md#build62快修)。
- 生产独立Review原3项及关联并发、失效记忆恢复问题全部闭环，独立复查通过；归档状态可信、恢复入口保留，已取消任务不能发布旧候选，当前正文可独立复查。
- 发布覆盖实际Build61至Build62全部改动；68个线上文件校验一致，停服备份、恢复演练、无变更迁移及内外网门禁通过，正文、业务数据与密钥保持不变。
- Backend 333 passed、12项旧协议skip；Store/HTTP 39项及状态测试通过。双端OS27 Release签名构建与严格验签通过。
- Mac已换装运行Build62，成稿、草稿编辑及失败原因页面可用；未触发生成、接受或重新归档，历史失败记录保持原样。
- iOS保持Build62的Xcode安装状态，无IPA；最终真机页面验收仍未完成，设备支持审计pending为空。
- 上线后完整性、外键、单实例与鉴权健康通过，无在途任务、无新增warning。交付与回退备份保留，本地及远端临时资源已按精确清单清理。

## 后续升级方向

- 补做iOS最终页面验收；用户通过Xcode完成真机安装。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。

## 里程碑索引

- v2.2.0（Build63，后端已部署）：Writer提示词加强Bible内过程展开与防凑字指导；保留4000字校验及既有重试，客户端仍Build62；[部署证据](archive/operations/2026-09-24-build63-deployment.json)。
- v2.2.0（Build62）：生产Review快修及关联问题已发布，Backend更新及Mac换装完成；[修复与验证记录](archive/operations/2026-09-24-build61-sop-flow-review.md#build62快修)。
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
