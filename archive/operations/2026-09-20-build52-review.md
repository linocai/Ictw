# Build 52 发布后全面审查

审查目标：`v2.1.0-build52` / `927c935477dd637e842dd0a3e2298d01aa47d87b`。主会话审客户端状态、通知与双端页面，独立 reviewer 审后端及公开错误契约。用户本轮只要求 review，本记录不代表已经修复或重新发布。

累计范围：公开客户端 `v2.1.0-build48` / `9cf48a8368bf12d27dcb7e2f00f0196322b6abe8` → Build 52；生产 Backend `65fafff` → `a298f690058718333eecd2391337a137f160733e`（与 Build 52 后端相同）。审查起点工作区干净，HEAD `d469a3f` 相对目标只有发布文档；不包含本报告或未提交产品变更。无本轮正式施工 Plan，以用户审查目标和已发布源码为准。

结论：通知快修已改善正常接收到的错误展示，但“所有阻碍都能正确显示原因”尚未成立。确认 9 项缺口；多数早于本次发布已经存在，不将其冒称为 Build 52 新引入的回归。

## Findings（按严重度）

1. **P1：接受正文被拒绝，会误报为章节已完成，主按钮无法恢复。**
   - 位置：`App/LinoI/LinoStores.swift:857–863`；`App/LinoI/V2Shared/V2DeskPresentation.swift:507–508,567–569`。
   - 触发：Checker 通过后另一处修改世界观／人物设定使检查指纹失效，再点接受会被后端 409 拒绝（已有后端用例覆盖）；未选人物、模型配置或网络错误也会进入同一分支，后端仍是 draft/draft_ready。catch 无条件把失败阶段设为 extraction；前端据此显示“记忆没能整理，这一章仍然是完成的”，主按钮变为“重试整理”。
   - 后果：状态与后端事实矛盾；重试在 `LinoStores.swift:871` 被 finalized 守卫直接退回，不能完成接受。已用实际共享展示代码隔离复现。应区分接受前失败与接受后归档失败，以服务器已接受事实决定状态及恢复动作。

2. **P1：iOS 已接受章节的归档失败，缺少章内原因和重试入口；重新打开时还会丢掉失败通知。**
   - 位置：`App/LinoI/V2IOS/V2IOSChapterDeskView.swift:20–21,83–116`；`App/LinoI/LinoModels.swift:1234–1236`。
   - 触发：正文接受成功、Extractor 失败。iOS finalized 章节一律进入 Reader，而 Reader 只画正文和阅读导航，更多菜单也没有 retryArchive；工作台已有的失败条不在这条显示路径内。
   - 后果：即使当时通知出现，关闭后章内没有恢复动作；冷启动/切回章节时，共享 reconciliation 把所有 finalized 上的 failed 当作 obsolete，不区分 extract，连通知历史也不会恢复。真实有效的归档失败判为 obsolete 已隔离复现。应保留当前 extract 失败，并给阅读页提供归档状态、详情与只重试归档的入口。

3. **P2：待同步修改被服务器拒绝后，只剩“待同步”，真实错误被吞掉。**
   - 位置：`App/LinoI/ClientSyncStore.swift:462–465,659–661`。
   - 触发：离线队列恢复提交时收到 401、404、422 或非冲突 409。handleFailure 只处理 transport，不保存/发布其余错误；队首保留并立即停止 flush。
   - 后果：双端仍显示在线、等待同步，没有失败原因或通知；重复尝试得到同样结果，后续队列也被阻塞。隔离 HTTP 422 服务实测：pending=1、online=true、无 failure/conflict。应保存该项安全错误原因，并提供可诊断的处理路径。

4. **P2：手动复查的上游失败，被后端压成 unavailable，前端无法解释原因，也不进入通知。**
   - 位置：`Backend/app/routers/chapters.py:872–877`；`App/LinoI/LinoModels.swift:1138–1150`；`App/LinoI/V2Shared/V2DeskPresentation.swift:582–588`。
   - 触发：手动 Checker 内容拦截、超时、上游拒绝或无效响应。后端返回 HTTP 200，仅保留 error_code，不保留安全错误上下文、模型和上游原因；DTO 也无对应明细。
   - 后果：页面只说“这次没能检查”，无 detail；Store 走成功回包分支，不发错误通知。以 llm_content_blocked 结果隔离复现。需同时补后端错误契约、审计记录、DTO、章内原因与通知；公开内容继续遵守候选脱敏边界。

5. **P2：手动复查在程序预检阶段被拦截，具体字数／人物原因在客户端被丢弃。**
   - 位置：`Backend/app/routers/chapters.py:830–838`；`App/LinoI/LinoAPI.swift:150–158`。
   - 触发：作者导入/粘贴短稿或含未选、重名人物的稿件后点复查。后端返回 detail.violations 的具体规则和明细，但 APIClient 只取 code/message/details.names。
   - 后果：通知只说“当前正文未通过确定性校验”，用户不知道缺字数还是人物未授权。应解码并展示安全 violations，或在后端 message 中明确概括；不放行正确性闸门。

6. **P2：轮询接口的鉴权或协议错误，统一伪装成临时连接中断。**
   - 位置：`App/LinoI/LinoStores.swift:1204–1209`。
   - 触发：写作/归档轮询返回 401、404、确定性错误或解码不兼容；catch 不区分错误类型。
   - 后果：仅通知“与服务器的连接暂时中断，正在自动重试”，且每 2.5 秒无限继续；真实原因没有保留到详情或历史，用户无法知道应改 Token、升级服务或处理其他问题。应区分可恢复网络波动与需要用户处理的错误，并保留任务状态未知这一事实。

7. **P2：服务重启恢复丢掉原任务阶段，前端可能把检查或选记忆中断标成整章写作失败。**
   - 位置：`Backend/app/main.py:69–72`；`App/LinoI/LinoStores.swift:1462–1475`。
   - 触发：服务在 selecting_memory 或 checking 阶段重启。恢复过程覆盖 phase 为 failed，仅写 interrupted，没有保存原阶段到 error_context。
   - 后果：客户端缺少 agent_role 时默认 drafting，“哪里受阻”的定位不真实。应在覆盖阶段前保存安全阶段信息，由展示层据此说明。

8. **P2：找灵感失败不接入通知记录，离开章节后原因会丢失。**
   - 位置：`App/LinoI/LinoStores.swift:1639–1642,1660–1667`。
   - 触发：灵感请求出错，只更新局部 errorMessage；未调用 NoticeBus。切换章节会清空该字段。
   - 后果：面板内能看到错误，但关闭面板期间完成的失败没有全局通知，切章后通知历史也查不到。应保留局部提示，同时发布带书章位置的安全失败通知，避免重复。

9. **P2：iOS 首次连接失败后，错误会被“已连接”成功提示覆盖。**
   - 位置：`App/LinoI/V2IOS/V2IOSRootView.swift:327–330`；`App/LinoI/LinoStores.swift:64–79`。
   - 触发：本机书架缓存为空，保存错误 Token 或不可用地址。bookshelf.load 在内部捕获错误，结束后 isLoading=false、books仍空；调用方仅凭这两个条件发送成功提示。
   - 后果：实际鉴权/网络失败被当前成功提示覆盖，用户被引导新建书。NoticeBus 先401错误再成功消息的替换结果已复现，完整 connect 调用链经源码核对。应让 load 显式返回结果，仅请求成功时报告已连接。

## 验证与边界

- 主会话：实际发布源码编译，客户端现有状态测试全部通过；额外 5 个隔离用例复现接受失败误分类、手动 Checker 无详情、finalized Extractor 失败被丢弃、连接提示被成功消息替换、同步 HTTP 422 静默。同步只连接本机临时 HTTP 服务，使用虚构 Token/数据；其他用例调用真实纯展示/状态层。不是双端真机故障注入，未声称上述 UI 在 iPhone 上逐一点击验证。
- 独立 reviewer：12 项相关 Backend pytest 通过，覆盖 Checker 上下文、手动预检、候选脱敏、JobRun 错误上下文、Extractor 失败/日志脱敏及重启恢复；diff --check 通过。
- 本次上下文修复未发现新的阻断：自动 Writer/Checker 使用同一事实快照；手动复查排除失败与未来历史；只有双重校验通过才能提升正文；被拒候选全文与逐字证据继续留后端。
- 已接入 NoticeBus 的错误具有详情、手动关闭及本次会话历史；普通后台写作失败的具体 Checker reason 能进入通知。这些已通过的局部路径不能代表所有失败入口已覆盖。
- 未调用真实生产模型、未修改生产数据、未做线上故障注入或重新部署；未重新验证 iPhone 真机运行及所有模型的语义表现。本轮未修改产品代码。

## 复现输出与资源收尾

```text
REPRO accept refused: draft_ready -> 记忆没能整理，这一章仍然是完成的; action=Optional(main.V2DeskPrimaryAction.retryArchive)
REPRO manual checker llm_content_blocked: 这次没能检查, no reason detail
REPRO current Extractor failure on finalized chapter: recovery=obsoleteTerminal; no restored notice
REPRO connection failure then empty-shelf completion: current notice=已连接，可以新建第一本书。
REPRO offline sync HTTP 422: pending=1, online=true, no failure state, no conflict
Client state tests passed
```

- 本轮主会话临时产物限定于 `/tmp/ictw-review52-20260920`：5 个文件，2730829 字节；本机 HTTP 服务与编译/测试进程已退出，lsof 核验无占用，逐项哈希复核后删除。保留本报告中的代表性结果；没有远端临时目录或故障注入。独立 reviewer 报告无额外测试临时产物。
- 清理后该目录占用 0 字节；产品源码与发布物未改动。未清除共享开发缓存或用户数据。
