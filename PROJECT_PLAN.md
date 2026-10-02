# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.4.0（Build76，已发布）**：改善跨章承接，让已发生进展、人物已知、上一章落点与未决事项可靠进入下一章；写作与检查共同尊重作者指定的过程、顺序和终点。保留五段写作链和简洁操作；[本轮施工与验收记录](archive/plans/v2.4.0-build75-chapter-continuity-plan.md)。

## 关键决定

- 检查依据与实际写作输入一致；结论有真实来源证据，服务失败不假报正文违规；作者短稿可先检查再决定接受。
- 人物授权保持严格，但普通词命中不直接当人物出场；人物选择和豁免在程序、模型与前端一致。
- 已生成新稿可在后台单独重试检查；候选正文仍不公开，通过后才能成为当前正文。
- 正文接受独立完成；归档失败始终只影响记忆。相同记录自动去重，无法确定的状态明确标注并遮蔽旧值，有效叙事事实可按新完整契约使用；旧失败归档不自动生效。
- 历史资料缺失时说明缺什么，允许作者知情继续；恢复顺序有引导，不自动重提真书。
- 保留用户已定三句创作边界与空Bible跳过规则；不按文字顺序猜最终状态、不增加隐形模型重试。
- 生成稿检查与当前正文复查分别恢复；检查服务失败明确说明尚无结论，不引导作者无故重写整章。
- 相同历史内容重新归档不打断写作；多人事实与关系身份完整传递，但历史不会扩大本章人物授权。
- 异步操作必须属于原书籍、章节及同次编辑上下文；旧响应不能覆盖新编辑。全局与不同书的设置、冲突和草稿各自独立；有效历史的展示与写作取材保持一致。
- 设置失败和离开编辑项不得静默丢输入；导出必须说明并解决遗漏本机修改的阻碍，草稿可独立保存，无需生成、检查或接受。可成功导出的项目包必须可恢复；真实冲突和人物授权不放松。
- Bible指导保持作者可编辑，不变成隐藏硬协议；异常断流不能当完整稿，完整重写仍最多一次。
- 故障须说明环节、具体原因、正文状态、真实恢复操作与定位编号；未知原因明确未知，检查器自身出错不假报文章违规。安全诊断可追溯，正文、候选原文和密钥不进入诊断日志或公开错误。
- iOS 章节页按“标题／意图／人物 → 正文 → 检查结果”组织，保留滑动并提供文字入口；保存、重写与检查恢复各有明确含义，不改变 Mac 工作台或模型调用规则。
- 紧邻上一章的有效承接资料直接交给 Writer 与 Checker；更远历史由 Selector 选择原文，避免重新概括时改变先后关系。旧归档继续可用，不自动重提历史。
- 跨章检查只约束有证据的事实、时间与作者指定顺序，允许回忆、日常重复、渐进关系和有意非线性叙事。质量优先推理由作者在现有模型设置中明确选择，不自动改变已存设置。

## 当前状态

- 当前生产、公开Release及已安装Mac为 **v2.4.0（Build76）/ `ff50abb`**，不可变标签`v2.4.0-build76`，数据库0016；[发布与恢复证据](archive/operations/2026-10-02-build76-deployment.json)。
- 双端OS27签名Release及严格验签通过；Mac成稿页和已有草稿编辑页已实际打开验证。iOS同版工程已准备好，供用户通过Xcode安装；未生成IPA，真机安装和页面尚未验收。
- Build75独立review的两项问题已由Build76修复并复查闭环：Backend640项通过、12项既有跳过；[快修验证](archive/operations/2026-10-02-build76-validation.json)。客户端功能代码未变，既有100项Store/HTTP、状态门禁和合成原生点验见[Build75证据](archive/operations/2026-10-02-build75-validation.json)。
- 生产迁移前后备份均已实际恢复验证，既有数据与模型设置保留，内外健康、完整性、外键及单实例通过；未重跑历史任务或调用真实模型。
- 限定只读调查发现：上一章有效资料确已传入；Selector有时序改写，Writer重复推进且Checker未识别。不能据此认定Extractor漏存、模型或字数门槛是主因。
- 工程验收使用中性合成数据与 fake LLM；不生成、重写或重提真书，不做内容质量 A/B。文学效果由用户自己验收，尚无质量改善结论。
- 用户既有Errors、工程排序与Mac scheme保持保护；本地及远端发布暂存已核验清理，交付物与恢复集保留。设备支持审计有一台`iPhone18,4`当前不可用，待现场核验，缓存保留。

## 本轮交付目标与后续升级方向

- v2.4.0交付：上一章承接资料完整直达，更远历史保留原文语义；重写、手动复查、旧归档和项目备份恢复保持一致。
- Writer避免把已知重新写成首次发现或提前用完同一转折；Checker在现有结果入口展示可追溯的承接与顺序问题，不增加文风审查或前端复杂配置。
- 双端现有模型设置提供明确可选的质量优先推理，说明可能更慢；用户自定义人格、模型和单书覆盖保持自主控制。
- 工程门禁、两项修复的独立复查和一条龙发布已完成，无遗留施工任务；iOS真机安装、页面和文学效果由用户验收。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。发布后新业务写入不得用发布前整库备份直接覆盖。

## 里程碑索引

- v2.4.0（Build75–76）：跨章承接、原文选择与显式质量优先设置已发布；两项review问题修复闭环，生产迁移、Mac换装及资源收尾完成，iOS待Xcode安装；[施工与验收记录](archive/plans/v2.4.0-build75-chapter-continuity-plan.md)。
- v2.3.4（Build73–74）：iOS交互与重写归属修复已发布，Mac换装完成，iOS待Xcode安装；[施工与验收记录](archive/plans/v2.3.4-build73-ios-interaction-plan.md)。
- v2.3.3（Build72）：写作SOP错误诊断与恢复说明已发布，Mac换装和资源收尾完成，iOS待Xcode安装；[施工记录](archive/plans/v2.3.3-build72-error-recovery-plan.md)。
- v2.3.2（Build71）：累计Build65–71修复已发布，Mac换装、后端升级及资源收尾完成，iOS待Xcode安装；[版本记录](archive/plans/v2.3.2-build70-sop-plan.md)。
- v2.3.1（Build69，已随Build71发布）：17项整体Review及当时复查边界本地修复验收完成，新发现13项纳入Build70；[版本记录](archive/plans/v2.3.1-build69-reliability-plan.md)。
- v2.3.0（Build68）：整体SOP复审5项快修，作者编辑保护与检查/归档恢复；[版本记录](archive/plans/v2.3.0-sop-reliability-plan.md#build68快修)。

- v2.3.0（Build67）：重写资料稳定复用、Bible人格提示词补充与姓名协议冲突快修；[版本记录](archive/plans/v2.3.0-sop-reliability-plan.md#build67快修)。
- v2.3.0（Build66）：SOP复审6项及复验边界快修，承接未发布Build65；[版本记录](archive/plans/v2.3.0-sop-reliability-plan.md#build66快修)。
- v2.3.0（Build65）：发布后独立复审7项快修，已并入Build66；[版本记录](archive/plans/v2.3.0-sop-reliability-plan.md#build65快修)。

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
