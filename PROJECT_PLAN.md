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

- **v2.2.0（Build60）已于2026-09-23完成一条龙发布**：Backend、公开Release和本机Mac均为 `b620558`，生产Alembic head为 `20260923_0014`。
- [21项Review发现](archive/operations/2026-09-23-build59-checker-sop-review.md)及复审新增问题已闭环；[完整执行与发布记录](archive/plans/v2.2.0-production-sop-plan.md)。
- 发布覆盖实际Build59 `e7b14b0` 至Build60全部改动；停服备份、真实库副本迁移、恢复验证及上线门禁通过，原有业务数据与密钥保持不变。未自动重提旧失败章节。
- Backend 305 passed、12项旧协议 skipped；客户端Store/HTTP 38项及状态测试通过，Checker、归档与中央生产链独立复审完成。
- 双端OS27 Release签名构建及严格验签通过；Mac已换装，真实成稿/失败原因/草稿编辑页验收通过。iOS保留Xcode安装状态，未导出IPA；最终真机页面验收仍未完成。
- 内外网健康、鉴权、文档关闭、单实例、完整性/外键及68个部署文件通过，发布后warning为0；本轮设备支持审计pending为空。
- 当前交付与回退物均已保留；本轮本地及远端暂存资源按精确清单清理，证据见发布记录。

## 后续升级方向

- 补做iOS最终页面验收；用户通过Xcode完成真机安装。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。

## 里程碑索引

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
