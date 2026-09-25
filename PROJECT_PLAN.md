# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.3.0（Build 64，已发布）**：iOS、macOS与Backend统一版本，修复本轮生产SOP Review的8项问题，让检查协议、错误说明、原文复查和历史记忆传递可靠衔接；[本轮施工与验收记录](archive/plans/v2.3.0-sop-reliability-plan.md)。

## 关键决定

- 检查依据与实际写作输入一致；结论有真实来源证据，服务失败不假报正文违规；作者短稿可先检查再决定接受。
- 人物授权保持严格，但普通词命中不直接当人物出场；人物选择和豁免在程序、模型与前端一致。
- 已生成新稿可在后台单独重试检查；候选正文仍不公开，通过后才能成为当前正文。
- 正文接受独立完成；归档失败始终只影响记忆。相同记录自动去重，无法确定的状态明确标注并遮蔽旧值，有效叙事事实可按新完整契约使用；旧失败归档不自动生效。
- 历史资料缺失时说明缺什么，允许作者知情继续；恢复顺序有引导，不自动重提真书。
- 保留用户已定三句创作边界与空Bible跳过规则；不按文字顺序猜最终状态、不增加隐形模型重试。
- 生成稿检查与当前正文复查分别恢复；检查服务失败明确说明尚无结论，不引导作者无故重写整章。
- 相同历史内容重新归档不打断写作；多人事实与关系身份完整传递，但历史不会扩大本章人物授权。

## 当前状态

- **v2.3.0（Build64）于2026-09-25完成一条龙发布**：Backend与已安装Mac均为`59ba659`；main和不可变标签`v2.3.0-build64`已推送，[Release](https://github.com/linocai/Ictw/releases/tag/v2.3.0-build64)已发布；[发布证据](archive/operations/2026-09-25-build64-deployment.json)。
- 本轮8项SOP问题及独立复查追加项均已闭环；Backend365 passed/12 skipped、客户端状态与44项HTTP测试通过，双端OS27 Debug及签名Release构建通过。
- 后端停服备份、恢复演练、无变更迁移及内外网健康通过；正文、任务、归档与密钥保持不变，只有Mac页面验收产生书籍打开时间更新。
- Mac已换装并正常运行Build64，成稿、已有草稿编辑及失败原因/恢复入口可用；保留Build62回退副本，未触发生成、接受或重新归档。
- iOS Build64签名产物与Xcode配置就绪，不生成IPA，最终安装由用户操作；真机页面尚未验收，iPhone Air当前不可用，待现场核验。
- 本地/远端发布暂存与恢复演练库均已核验清理；保留当前交付、符号、iOS安装产物及已验证回退集。

## 后续升级方向

- Build64已发布；后续问题按实际使用情况继续处理。
- 补做iOS最终页面验收；用户通过Xcode完成真机安装。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。

## 里程碑索引

- v2.3.0（Build64）：Checker、复查恢复、章节所有权与历史记忆衔接修复已发布，双端统一版本；[施工记录](archive/plans/v2.3.0-sop-reliability-plan.md)、[发布证据](archive/operations/2026-09-25-build64-deployment.json)。

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
