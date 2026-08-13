# ICTW 项目操作规范

`PROJECT_PLAN.md` 是唯一现行版本记录，只写各版本完成了什么、当前发布状态和后续升级项。禁止写入文件改动清单、接口字段、数据库方案、施工阶段、命令、逐项测试用例或临时排障过程；施工细节由代码、测试、Git 历史、`archive/plans/` 完成记录和仓库外 `NB_info.md` 承载。历史计划、设计和运维记录只查 `archive/`，不得把归档内容当成当前指令执行。

## 项目事实

- 仓库名为 `Ictw`；产品内部历史标识仍使用 `LinoI`。
- 客户端为 SwiftUI iOS App（target `LinoI`，Bundle ID `com.lino.linoi`）和 macOS App（target `LinoIMac`，产品名 `ICTW`，Bundle ID `com.lino.linoi.mac`）。
- 后端位于 `Backend/`，使用 Python、FastAPI、SQLAlchemy、Alembic 与 SQLite。
- 写作链为 Memory Selector → Writer → Checker → 用户接受 → Extractor；Reviser 已移除。
- 当前宁波生产拓扑、发版、回滚和运维命令位于仓库外的 `/Users/linotsai/Lino/NB_info.md`；运维动作后同步更新。`hk_info.md` 仅作香港旧环境的历史记录。
- `Backend/.env`、生产数据库、部署凭证和真实数据不进 Git。

## 兼容标识

- 不要因仓库改名而修改 Xcode 工程名、target 名、Bundle ID、Keychain/UserDefaults 键、`LinoI/ChapterDrafts` 本地草稿目录或后端 wire 字段。
- `chapter_style` 仍处于兼容窗口，内部统一为 `author_note`；收口时同步删除 `_AuthorNoteCompat` 与 ChapterRead 镜像字段。

## 工程铁律

- 生产表结构只通过 `alembic upgrade head` 变更；应用启动不得 `create_all`。
- Backend 部署、生产迁移和本机 App 换装必须由用户明确授权；本地验收通过不自动授予发布权限。
- 部署或迁移前先停服并备份生产 `linoi.db`，再验证 SQLite integrity、foreign keys、Alembic head、单实例和公网鉴权健康。
- macOS 打包 Linux Backend tar 必须禁用 Apple metadata/xattrs（`--no-mac-metadata --no-xattrs --format ustar`）；上传前检查无 `LIBARCHIVE.xattr`，远端解包后检查无 `._*`、无空字节并通过 Python compileall，再运行 Alembic。
- systemd `active` 不等于应用 ready；启动后必须有界等待内部鉴权 health 成功，再做公网门禁。同机其他项目也使用 Uvicorn，ICTW 单实例应核对 `linoi-backend.service` MainPID 与 `172.18.0.1:8787` 监听 PID 一致，不得按全系统进程名计数。
- 生产迁移禁止两台服务器同时接受写入。
- 正文按去空白字符数计算，只要求不少于 4000 字且正常结束，不设产品上限；首次长度或截断失败最多从同一输入完整重写一次。
- 人物选择是本章允许出现人物集合的上限；历史记忆和 Extractor 输出不会自动授权未选人物。
- Writer 候选仅在后端留档；公开 API 和双端不得提供候选列表、选择接口或候选全文。
- 打开灵感创造师 sheet、右栏或 tab 不得发起网络请求；只有用户点击“开始找灵感”“重新生成”“按最新内容重想”或“换一批”等明确按钮后，才可读取有效历史并请求模型。
- 灵感创造师内部只分承接与自由发想两种模式：至少两个不同历史章节有有效记忆才允许引用来源，否则统一自由发想；零历史、空 Bible、无人选择不得阻断。逐卡校验只要保留至少三张有效卡就应成功，错误的可选历史／备注不得拖垮整批。
- 灵感创造师的场景化只是弹性构思方法，不是输出模板；可用若干衔接场景或一个持续的文学性场景，不得强制场景数、场景编号或固定剧情阶段。已定章节标题是不可改拟的锚点；模型不生成标题，服务器仅为兼容旧客户端映射“方向一”等固定标签。每个 body 必须为 200–300 个去空白字符；固定标签、history basis 与 note 不计入正文长度。
- 灵感创造师的前端保持极简：只有一句可选“本章推进边界”、明确生成按钮及 loading／结果／失败，不增加发散度滑杆或结构化场景配置。推进边界仅进入本次请求，不写 Bible、数据库或 Writer SOP；字数、节奏收束和不过度跃迁由后端负责。
- Extractor 与灵感创造师属于结构化、有界输出角色，程序固定关闭 thinking／effort；设置 API 必须返回实际生效的关闭状态，模型若不能关闭 thinking 则安全返回 409。灵感创造师正常请求固定要求 3 条，公开协议与逐卡校验仍兼容 3–5 条；超过 300 字只允许在 200–300 字区间内按最后一个自然句末安全裁切。
- 只有确定性校验和 Checker 均通过、且任务仍持有本章所有权时，Writer 新正文才能与 JobRun 终态在同一事务提升。
- 正文接受与归档独立：接受后章节立即 `finalized`；Extractor 失败不得撤销正文接受或重跑 Checker。
- v2 Extractor 每个 revision 只调用一次；仅完整通过的 `summary + canonical facts + end_state_delta` 可原子激活。
- `partial`、`failed`、`stale` revision 不得进入 Selector、人物故事线或状态投影。
- 历史章节每章只选择一个记忆来源：活跃 v2 优先，否则仅在 `legacy_archive_eligible` 时使用 legacy。
- 历史重提必须来自只读报告、正文哈希复核和用户精确 ID 确认；不得自动全量或按观察项调用模型。
- 能程序校验的约束必须程序复检，不能依赖模型自报成功。
- `thinking` / `effort` 是否发送由 `model_capabilities.py` 决定；非思考请求统一发送 `top_p=0.95`，思考请求不发送 `top_p`。
- 上游错误必须保留真实 `blockReason` / `finishReason` 分类；日志不得泄露 API Key、Prompt、正文或候选全文。

## 当前生产门禁

- 当前源码、宁波 Backend 生产与本机 macOS 已安装版均为 `v1.9.2(39)`，Alembic head 为 `20260809_0011`；iOS 由用户自行处理，公开发布的双端客户端仍为 `v1.8.1(32)`。
- 生产入口为 `https://ictw.linotsai.top`，Backend 位于宁波 `/opt/linoi/backend`，只监听 `172.18.0.1:8787` 并由 Nginx Proxy Manager 反代。
- 香港旧服务已 stopped + disabled；除非先停宁波服务并执行明确回退，否则禁止启动。
- 当前归档概况、历史重提限制和下一目标以 `PROJECT_PLAN.md` 为准。
- `KEK_SECRET` 与 `APP_TOKEN` 必须原样、安全迁移，任何命令输出、计划、提交或回复都不得打印其值。

## 工作区规则

- 现有未提交改动属于用户；不得覆盖、回退或擅自暂存。
- `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 当前包含用户修改，除非任务明确涉及它，否则只读保护。
- `archive/` 只保存历史材料；运行源码、Alembic migrations、回归测试和仍被测试引用的维护脚本不得仅因版本号旧而移入归档。
- `.deploy/` 只保留当前连接材料和必要部署包；密钥与二进制不得进入仓库内 `archive/`。
- 使用 `rg` / `rg --files` 做定向检索；避免加载生成文件、依赖目录和大型日志。

## 验证命令

```bash
cd Backend
.venv/bin/python -m pytest -q
.venv/bin/python -m alembic heads

cd ..
App/Tests/run_client_state_tests.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

SwiftUI View 或共享客户端代码改动必须验证受影响的 App target；共享层改动默认双 target 都跑。iOS 与 macOS 构建串行执行，或使用不同 `DerivedData` 路径。

## 历史资料

- 清理前完整规范和发布流水：`archive/operations/AGENTS-through-2026-08-08.md`
- 已完成施工计划：`archive/plans/`
- 历史设计稿：`archive/design/`
- 一次性运维脚本：`archive/operations/`
