# ICTW PROJECT_PLAN

> 唯一现行版本记录。这里只保留产品目标、关键决定、当前发布状态和升级方向；详细施工与验证见精确链接的版本记录。

## 当前目标

**v2.3.3（Build72，已发布）**：修复整个写作流程失败原因丢失与双端通知不明确的问题；检查器返回无效证据时保留具体诊断，手动重试针对真实原因，始终说清正文状态和可执行的恢复操作。[施工与验收记录](archive/plans/v2.3.3-build72-error-recovery-plan.md)。后端与Mac已发布，iOS已签名构建供Xcode安装。

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

## 当前状态

- 当前生产、公开Release及已安装Mac为 **v2.3.3（Build72）/ `1e5eb8e`**，不可变标签`v2.3.3-build72`，数据库0015；[发布与恢复证据](archive/operations/2026-09-30-build72-deployment.json)。
- Build72已修复Checker安全细因、真实失败环节与正文状态的传递；双端通知说明可执行恢复，未知接受结果只刷新确认。不新增模型自动重试或历史任务重放。
- 后端573项通过、12项既有跳过，客户端95项HTTP与状态门禁通过；200个受测源码文件与发布构建一致。双端OS27签名Release和严格验签通过。
- Mac已换装，成稿与已有草稿编辑页正常；隔离Checker、归档和接受恢复流程此前已点验。iOS供用户Xcode安装，无IPA；原生页面未点验（此前DeviceHub超时）。
- 停服备份、压缩备份恢复、数据库完整性/外键、内外健康与单实例通过；发布前后业务数据一致，页面验收仅改变书籍访问时间。未调用模型或重跑旧任务。
- 发布暂存与构建临时资源已清理，当前交付物和可恢复回退集保留；用户既有工作区改动与Mac scheme受保护。

## 本轮交付目标与后续升级方向

- 写作、检查、接受、归档的失败均可从双端通知和任务详情读懂、定位，并只提供当前确实可执行的恢复；旧记录与未知故障诚实降级。
- Build72正式发布完成；iOS最终真机安装由用户通过Xcode进行，安装后的原生页面尚未验收。
- 旧失败归档由作者在对应章节主动重试；不自动批量重提。发布后新业务写入不得用发布前整库备份直接覆盖。

## 里程碑索引

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
