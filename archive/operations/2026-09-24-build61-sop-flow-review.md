# Build61：昨晚生成故障与 SOP 畅通性复审

## 范围与状态

- 用户目标：解决2026-09-23夜间生成失败，并审查整条小说生产 SOP 的畅通性；按快修实施，版本保持2.2.0，Build增至61。
- 实际部署基线：`b62055854d0e2f198db059a1e8ca271e8ecd0630`（v2.2.0-build60）。本轮本地基线：`0256014b4bcc29437eb232be450e515bec012500`。两者之间为发布记录收尾，无业务实现差异。
- 审查覆盖当前 Memory Selector → Writer → Checker → 接受 → Extractor → 失败恢复及双端通知/任务卡；包括本轮全部工作区改动和新增回归测试。没有新正式 Plan；以本轮用户授权和既有产品约束为依据。
- 当前为本地修复验证，未部署、未换装、未提交发布标签；线上仍Build60。没有迁移或数据库结构变更。

## 生产证据（北京时间）

2026-09-23 22:42—23:02，《在这个世界》第9章有6次write失败和1次单独Checker重试失败：4次Selector失败（候选外来源、2次结尾ID无效、18个来源超过16个）；2次已生成4662/4600个去空白字符，确定性校验通过但Checker协议失败；一次Checker单独重试仍失败。模型调用结束标记均为stop，没有记录到限流、超时或上游内容拦截。

旧代码只记录`checker_invalid_response`，具体Validator理由被丢弃；所以无法反推昨晚每一份原始回复。对留存4600字候选做一次只读模型复现，得到`passed + issues=[] + name_uses(character)`，唯一待辨别名字在Bible中，人物未被本章选择；旧校验器因缺少重复身份issue拒绝整个结果。这个复现证明了可触发的具体根因，不冒充恢复了昨晚原始模型回复。

第6—8章当晚已完成归档；本次失败不属于旧重复状态归档问题。

## Findings 与处理

| 严重度 | 确认问题 | 修复结果 |
|---|---|---|
| P1 | Checker要求模型既分类人物、又重复写身份issue；漏后一项会把已知人物授权问题变成不可用结果 | 分类仍由模型决定；程序从冻结命中、已选人物和真实来源补齐身份问题。character至少violation，uncertain至少suspect，绝不自动授权或放行 |
| P1 | 隐藏生成稿单独重试Checker再次失败时，客户端清空重试入口，并可能把隐藏候选检查结果当成当前正文结果 | write/check失败均保留后端返回的source ID；只使用visible_checker_result恢复当前正文；连续失败仍可重试 |
| P2 | 长UUID和复合来源ID容易抄错；结尾选择的小错误阻断全部生成 | 请求内使用M/E短编号；只恢复精确且唯一的既有来源，重复来源去重；无效结尾退回原有700字内的上一章原文，记录诊断；未知或歧义事实来源仍拒绝 |
| P2 | “总来源16个”的指导数量被当成正确性硬门槛，18个合法来源使整章失败 | 改为指导/审计信息；保留每条来源真实性、单条6来源、8简报/4冲突、2400字记忆预算，不丢弃未证实事实凑数 |
| P2 | Checker具体失败原因在后台/手动路径丢失，自动链LLM审计还把校验失败记为成功；前端Selector泛化文案盖住具体原因 | 固定安全的程序原因保留到job/前端；自动Checker校验进入同一审计边界；不输出模型原回复、引文、Prompt或凭据 |
| P2 | 可用legacy历史被报不完整；无关或已解决的旧未知状态重复弹确认 | 依据实际可读legacy来源和当前有效、所选人物相关的未知槽提示；关系任一端相关即保留提示；整章缺失仍允许知情继续 |
| P2 | 仅提示文案/分类变化也会使原候选失效，升级后阻止重查 | 保留冻结快照原哈希完整性及全部真实输入依赖校验，移除仅advisory列表与当前文案的相等要求 |
| P2 | 输出截断提示固定说Extractor、宣称会自动压缩重试；通用Checker失败提示可能诱导绕过接受隐藏稿 | 更正为实际失败环节的重试建议，不再承诺不存在的自动流程 |
| P2 | 候选因输入变化、不可重试或已不存在而被后端拒绝后，前端仍保留过期重试按钮 | 仅在同一操作仍有效且收到明确永久失效代码时清除入口，回到重新生成；临时冲突/网络失败不清除 |
| P2 | 后端/job仅按失败代码宣称可重查，真实输入已失效的按钮会在刷新后重新出现 | /job与重试接口共用候选有效性证明，校验冻结输入、正文哈希和写作代际；升级前仅提示文案不同仍可重查 |
| P1 | 隐藏候选的identity_issues元数据仍从公开检查接口返回，违反仅kind/reason的约定 | 隐藏结果剔除name_uses及identity_issues；当前可见正文/手动复查仍保留人物修复选项 |

定位：`Backend/app/agents/memory_selector.py`、`services/context.py`、`services/checker_validation.py`、`services/write_jobs.py`、`services/production_context.py`、`routers/chapters.py`；双端共享`App/LinoI/LinoStores.swift`、`LinoModels.swift`、`LinoErrorPresenter.swift`。细节以Git diff和回归源码为准。

## 验证

- 新增`Backend/tests/test_build61_sop_flow.py`：短编号、原文结尾回退、18个合法来源、未知/歧义来源不放行、字数上限、Bible/正文身份问题、legacy和有效未知提示范围、旧快照可恢复、错误可见性和审计不泄露原回复。
- Store/HTTP：连续两次Checker重试失败仍能继续，且不污染当前正文检查状态；38项通过。客户端状态测试通过。
- 双端OS27 Debug App target构建成功。Xcode27、SDK27、最低OS27；未运行或替换生产App，未生成IPA。设备支持审计pending为空。
- 真实模型只读验证：修复后的Checker得到有效`violation/unselected_character`；Selector得到有效6条简报+1条冲突、16个来源。验证使用独立只读数据库连接和进程内代码，不写生产文件/任务/正文，不触发Writer、接受或Extractor。
- 全量Backend与独立复查最终结论、资源收尾见下方收口记录。

## 保留的边界

- 本轮不自动补选“蒋语笛”或改书稿；作者需按实际创作意图补选人物、调整Bible或处理姓名豁免。人物未选属于真实授权问题，修复后会明确显示而非自动通过。
- 完全缺失的旧章仍保留知情提示：不能仅凭无共享人物断言它对世界观/剧情无影响；提示可确认继续，不要求自动重提。
- 未将一次真实模型成功视为保证所有未来输出成功。无依据的事实引用、不可验证证据、真实授权冲突及不可用模型仍会明确失败。
- 不开展真实书稿自动重提；不自动修改生产配置或发版。iOS真实设备最终页面不在本次本地验证范围。


## 最终收口（2026-09-24）

- 11项已确认问题全部修复。独立reviewer完成本轮修复与影响范围复查，未发现剩余可报告问题；独立重跑3项Backend定向回归和38项Store/HTTP。
- 最终Backend：322 passed / 12旧协议skip。State通过；Store/HTTP 38通过；最终Swift改动的macOS/iOS App构建均成功，保护的Mac scheme哈希不变。
- 精确源码SHA256、真实模型验证的安全摘要、设备审计及资源清理摘要见[验证证据](2026-09-24-build61-validation.json)。后续源码变化不能沿用本次结论。
- 本轮主会话临时构建、测试数据库、日志和诊断脚本按精确清单校验未占用及内容未变后移除；含首轮构建/默认pytest临时目录与末轮Backend目录，共清理526089261个逻辑字节→0。Store/HTTP自清理，reviewer临时产物亦已核验清理；旧的其他任务pytest目录保留，未清共享临时目录。远端未写任务文件，相关路径核验不存在。
- 保留回归源码、本报告与紧凑验证JSON；本地工作区未提交，线上和已安装App仍Build60。下一步如用户要求发布，按现行一条龙流程审查Build60→Build61累计改动后部署/换装。

## 一条龙发布完成（2026-09-24，用户另行授权）

- 累计范围：实际部署Build60 `b62055854d0e2f198db059a1e8ca271e8ecd0630` → Build61 `a8a38dd6b9f5f3098ddeebf26c6a94cd303d21a1`，共23个路径；19个源码/测试文件与本地最终验证SHA256完全一致，无依赖/迁移变化。main已推送，不可变标签`v2.2.0-build61`指向该实现commit；后续文档提交不移动标签。
- [公开Release](https://github.com/linocai/Ictw/releases/tag/v2.2.0-build61)已发布。Mac ZIP SHA256为`2a0d866f81cab4651fbbd8dc6cbc87f5c700770a668bb1d0c247f6edfce763e3`，GitHub asset digest一致。
- Backend：先核验线上68文件与Build60一致且无在途任务，再停服备份；真实库恢复副本运行Alembic head，证明迁移为空操作且数据相同。生产更新后内外鉴权health200、未鉴权401、docs/openapi/redoc404、完整性/外键、单实例MainPID与8787监听PID一致；发布后warning0、在途任务0、68文件与目标哈希一致。密钥未变，除书籍打开时间外所有业务表内容与发布前一致。
- 远端恢复集：`/opt/linoi/backups/20260924-build61-a8a38dd`，保留旧代码、环境、旧marker与前后数据库；数据库经完整性与恢复核验、字节相同后硬链接去重，保留前后两个恢复入口，节约21835776字节。旧香港服务未操作。
- 双端OS27 Release均构建成功并严格验签。Mac导出使用命令行manual Developer ID签名，hardened runtime开启、无get-task-allow；受保护scheme哈希未变。iOS签名Release产物留在Xcode DerivedData供用户安装，无IPA。
- `/Applications/ICTW.app`已换装且运行Build61，使用ditto复制；交付app、ZIP解包、已安装app逐文件一致并通过签名验证。旧Build60完整且已验签备份位于`/Users/linotsai/Lino/app_backups/ICTW-v2.2.0-build60-before-build61-20260924.app`。
- Mac实际验收：已接受第8章页面可打开；重新编辑确认可取消；现有第9章TextEditor可打开；历史失败原因弹窗和重试入口可见。历史日志仍显示原“18来源超过16”错误，不篡改旧结果；未点击生成/重试、接受、重提或修改正文。iOS最终真机页面未验收。设备支持审计pending为空。
- 交付及完整发布证据：`/Users/linotsai/Lino/app_builds/ICTW-v2.2.0-build61-macOS.app`、同名前缀ZIP/dSYM、`ICTW-v2.2.0-build61-validation.json`、设备审计与local/remote-cleanup清单。
- 资源收尾：本地临时包、归档、导出、日志及已备份旧安装目录核验未占用、内容哈希未变后清理，28263794逻辑字节/27908KiB磁盘占用→0；系统与用户临时目录的本轮命名路径无残留。远端stage、上传包及恢复演练库23612532逻辑字节→0；保留现役交付和恢复集，`/opt/linoi`收尾占用459736KiB。未扫共享目录、未删除真实业务数据。

## Build62快修

用户在生产版独立Review后授权快修；基线为`55ece809b893d621a84e7e37c229f96aa934de56`，运行源码等同已部署`a8a38dd`。保持营销版本2.2.0，仅build递增62；本轮未授权新的部署/换装，生产和已安装App保持Build61。

- 原P1：Extractor最终生命周期/指纹校验与revision、chapter、JobRun终态在同一短SQLite CAS中执行；刷新证明依赖，模型调用仍在锁外。后章归档与前章重开、当前正文更新的屏障回归通过。
- 原P2：当前正文的有效手动复查清理已被取代的非归档失败、持久outcome及隐藏生成稿retry句柄；归档失败和不可用Checker不被误清。iOS证据页补独立复查按钮，遵守任务忙/网络状态，不触发自动调用。
- 原P2兼容接口：无If-Match任务同样在状态证明前取得CAS；replace-write不能抢accept/extract。可替换write/check在配置准备成功后原子移交registry，旧任务终止与新任务注册共用数据库事务；不在持有SQLite写锁时等待worker或另开写会话，提交失败有精确代际补偿。
- 复查关联P2/P3：既存complete但指纹失配的归档只读显示为stale且允许作者重试；详情、列表与状态投影以逐章验证的有效前缀为准，失配delta不进入后章。再次重试失败不回显虚假complete，成功后新状态才可生效；不自动重提或修改真实数据。
- 复查关联P2：单独重试Checker的最终提交也受registry所有权保护；替换任务提交失败、旧任务补偿尚未完成时，已取消Checker不能提升隐藏候选或覆盖正文。屏障回归验证旧JobRun取消、候选非current、原正文不变且无残留活跃任务。
- 回归覆盖11项Backend隔离HTTP/SQLite场景（仅模型为fake），包括替换任务正常/提交失败与既存失配→重试失败→恢复成功；全量333 passed / 12旧协议skip。Store/HTTP增至39项并全过，客户端状态测试及双端OS27 Debug App target构建通过。受保护Mac scheme未变；无生产写入、无真实模型请求、无IPA。最终复查与清理结果见下方收口。

### Build62收口（2026-09-24）

- 独立reviewer对基线至最终12个运行/测试文件逐一核对SHA256并复查，未发现剩余可报告问题；独立重跑失配归档恢复、Checker替换回滚竞态两项HTTP/SQLite测试，2 passed。原3项及复查关联问题全部闭环。
- 最终验证：Backend 333 passed / 12旧协议skip；Store/HTTP 39通过、状态测试通过、双端OS27 Debug构建通过；Xcode27、最低OS27、受保护scheme哈希未变。精确源码与验证摘要见[Build62验证证据](2026-09-24-build62-validation.json)。未覆盖真实模型、Build62签名发布、真机页面操作。
- 资源收尾：本轮独立目录按4776项精确清单复核内容未变、无占用后移除，553803744逻辑字节／552596KiB磁盘占用→0；Store/HTTP另自清理469项、8566669字节→0。reviewer复现文件及SQLite fixture已清理；系统与用户临时目录的本轮命名路径无残留。本轮未创建远端产物，未触碰共享发布物、真实数据或回退备份。
- 保留回归源码、现有记录与紧凑验证JSON；工作区未提交、未部署、未换装，生产和已安装App仍为Build61。后续发布需按实际Build61至Build62累计改动审查并完成一条龙验证。
