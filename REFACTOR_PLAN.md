# 拆分作业单（3 级）

规矩见 **CONVENTIONS.md**。这里是**待办与进度**，一次只做一条三级步骤，做完打勾并把验收结果写在后面。

- **一级** = 阶段（A 铺路 / B 拆文件 / C 收口 / D 目录分层）
- **二级** = 一个文件（或一组）
- **三级** = 一条可独立验收的动作（写完就能跑解析 + 冒烟）

> 纪律：**一次只改一个文件的一处**，改完立刻自查（见 CONVENTIONS 第六节）。
> 每条二级任务结束都要走一遍 C1 验证阶梯。

---

## 一级 A：立规矩、铺路

### A1 代码宪法
- [x] **A1.1** 写 `CONVENTIONS.md` —— 文件 / 分区与索引 / 模块边界 / GDScript 写法 /
  提示词与缓存 / 验证阶梯 / 仓库与密钥 / 换后端 / 与 AI 协作，共九节（含本项目踩过的坑）

### A2 索引地图
- [x] **A2.1** `tools/probe_map.gd`：全仓地图（行数 / 一句话职责 / 函数与 @export 数 / 分区行号区间）
- [x] **A2.2** 地图给超过 500 行的文件打 `⚠ 该拆`，并检查有没有「体量豁免」那行
      —— 首次跑出来 **7 个超标**：`desktop_pet.gd` 2525 / `pet_shell.gd` 1124 /
      `pet_memory.gd` 966 / `pet_chat.gd` 745 / `pet_rig.gd` 708 / `pet_harness.gd` 541，
      外加 `tools/probe_memory.gd` 580（自检也要守规矩，见 B7）
- [x] **A2.3** 主脚本头部索引 + README 都指向地图命令

## 一级 B：拆 >500 行的文件（一次一个文件，验完再下一个）

### B1 `pet_chat.gd`（851 → 目标 ≤500）—— **进行中**
- [x] **B1.1** 搬出内部类 `Conn`（单条连接的状态机）→ **`pet_conn.gd`（123 行）**
      —— pet_chat **851 → 745 行**。用 `const Conn := preload(...)` 顶替内部类，
      原来 40 多处 `Conn.new()` / `Conn.DONE` **一行都没改**，所以行为零变化。
      验收（2026-09-23）：解析 ✓ / `probe_memory` 87 项全绿 ✓ /
      **`probe_live` 四条路全过** ✓ / 冒烟 10 秒 stderr 干净 ✓ / 导出 12:33 ✓
- [x] **B1.2** 搬出流式解析 → **`pet_sse.gd`（165 行）** —— pet_chat **745 → 676 行**。
      落点盘过之后确认是干净接缝：`_reply` / `_reasoning` / `_emit_started` / `_pending_emit`
      这四个状态**只有解析层读写**，宿主只在三处（发请求 / cancel / 429 重发）reset 它们 →
      状态跟着解析器走，宿主改成调 `_parser.reset()`。
      信号留在宿主（新增 `_drain_parser()`：每帧把队列里的增量交给 `token` / `thought`），
      于是解析器不依赖任何场景 —— **能整段离线测**（probe_memory 新增 5 项：
      半个多字节字符切分能接回来 / `reasoning_content` 是 null 不崩 / 流里的错误对象 /
      "报错被当正文吐出来"一个分片都不冒 / choices 为空那块也收得到 usage）。
      验收：解析 ✓ / probe_memory **92 项**全绿 ✓ / **probe_chat_stream 全绿** ✓
      （它是这条链路的白盒探针，注入点从 `_drain_sse` 改成 `_parser.feed` ✓）/
      probe_live 四条路全过 ✓ / 冒烟 ✓ / 导出 12:43 ✓
- [x] **B1.3（部分）** 搬出两块，pet_chat **676 → 599 行**（**还没进 500**，见 B1.4）：
      - 「429 重试」→ **`pet_retry.gd`（70 行）**：只管**决定**（重发哪条 / 还剩几次 /
        什么时候），真正 `start()` 请求的动作留在 pet_chat（那是连接层的事）→ 能离线测
      - 「一次性请求」→ **`pet_once.gd`（120 行）**：自带一条连接，职责只有"发出去 +
        把响应原样交回来"（`got(code, body)` / `failed(msg)`）；**解释响应留在宿主**
        （`_on_bg_got`）—— 放模块里的话 429 重试会被信号时序绕过（先报了失败，
        调用方把任务名清掉，重试回来的结果就没人要了）
      - 手法：`_remember_request` / `_schedule_retry` / `_looks_busy` 留成**薄壳**，
        调用点一行没改；`pet_once.parse()` / `build_body()` 写成 **static**，离线可测
      验收：解析 ✓ / probe_memory **92 项**全绿 ✓（其中"等待重发也算忙"那条改成
      打桩在新模块上 ✓）/ probe_chat_stream 全绿 ✓ / probe_live 四条路 ✓ /
      冒烟 ✓ / 导出 12:54 ✓
- [x] **B1.4** 收口完成：pet_chat **599 → 496 行** ✓（地图里不再打 ⚠，也不用写体量豁免）。
      搬出去四块，每块都「一个文件一件事」：
      - **探活**（`_step_short` / `_short_get` / `reachable_set` / `_probe_path` + 它那条连接
        + 间隔 + 超时 + 可达值）→ **`pet_probe.gd`（90 行）**。特意把**超时和可达值放在一起**：
        这条以前漏过超时（半开连接会让 `busy()` 永远 true → 此后再也不探活，可达值卡死）
      - **地址 / 请求头 / 请求体 / messages 拼装**（`_parse_url` / `_headers` / `send()` 的 body /
        `compose_messages` / `_user_content`）→ **`pet_net.gd`（91 行）**，全是 **static**，
        所以能离线量"两轮之间前缀有多长"（前缀缓存就吃这个）
      - **token 账**（`_usage_field` / `cache_hit_tokens` / `cache_miss_tokens` / `log_usage`）
        → **`pet_usage.gd`（47 行）**，纯 static
      - 手法还是**薄壳**：`reachable_set` / `_headers` / `_parse_url` / `compose_messages` /
        `cache_hit_tokens` …… 全部保留原名转调，所以调用点和探针一行都没改
      - ⚠️ **踩到一个真回归**：搬完忘了把 `pet_probe` 的 `reachable_changed` 接回自己的
        `reachable` 信号 → `probe_offline` 与 `probe_chat_stream` 立刻抓到
        （`reachable 信号=[]`）。这类"对外接口断了一根线"正是那两条自检存在的意义
      - ⚠️ 另一个坑：`_get()` 撞 `Object` 的内置虚函数名 → 直接解析失败，改名 `_fire()`
      验收：解析 ✓ / probe_memory **92 项** ✓ / **probe_offline 全部通过** ✓（抓回归那条）/
      **probe_chat_stream 全绿** ✓ / **probe_live 四条路全过** ✓ / 冒烟 ✓ / 导出 13:02 ✓

### B2 `pet_harness.gd`（约 540 行 → ≤500）
- [x] **B2.1** 搬出「改 dsh 设置文件」那层（含备份 / 还原 / 权限预设）→ `pet_dsh_settings.gd`
      *实际降到 **464 行**（540 → 464，−76）：常量和那几支纯字符串函数搬走后，留下的壳比预计的多
   （探针和设置面板一直写 `PetHarness.XXX`，那些名字得留住）；464 ≤ 500，一步达标 ✓*
   - 搬的是 `dsh_home` / `settings_path` / `read_setting` / `read_effort` / `with_setting` /
     `with_effort` / `leading_ws` + `_swap_settings` / `_swap_back` / `_write` + 备份状态
     + 五个段名/键名常量；pet_harness 那边常量改成**别名**（`const PRESET_KEY := DshSettings.PRESET_KEY`），
     单一真源还是新模块
   - 一处接口调整：`swap()` / `swap_back()` 原来直接写 `last_error`，现在**返回**错误说明，
     由 pet_harness 的壳挂到自己的 `last_error` 上（模块不该知道"桌宠怎么报错"）
   - ⚠️ 踩到一处残留：`shutdown()` 里还写着 `if _settings_dirty:`（那个字段搬走了）→ 解析失败；
     改成直接 `_swap_back()`（"没动过就别写"由模块自己判断）

### B3 `pet_rig.gd`（约 710 行 → ≤500）✓ 完成
   - [x] **B3.1** 搬出「动画采样与统计」→ `pet_rig_stats.gd`（124 行）：`_measure_action_ends` /
     `_action_time` / `_sample_meshes` / `_sample_positions` / `_max_node_delta`
     + 三个阈值常量 + 候选动作表。全是 static，宿主节点当参数传
   - [x] **B3.2** 复核：剩 610 行**不是**只有「装配」—— 里面还有两套只关贴图的机制
     （消白边：harden + dilate；消棱边锯齿：UV 内缩那一族），所以**没走豁免、再切一刀**
     → `pet_rig_tex.gd`（232 行）
   *结果 pet_rig **707 → 413 行**（≤500 ✓，不需要记账豁免）。*
   - 验收：解析 ✓ / 开局日志逐项对得上（材质加固：567 个 surface 共用 1 个材质、filter=0、
     scissor=0.50、dilate=2px；UV 内缩 0.50 texel、重建 567 个网格）✓ /
     `probe_anim_stats` 表正常且「计时短于动画的动画数: 0」✓ /
     `probe_texture` 复核前提（岛间空白 RGB 全黑、偏亮占比 0.0%）✓ / 冒烟 ✓ / 导出 13:29 ✓
   - 唯一改到行为的一处（顺手）：`_inset_tri` 里的 `pet.uv_inset_texels` 改成**参数** `inset`，
     由 `inset_uvs` 往下传 —— 同一次内缩用同一个值，不再让底层函数自己去摸宿主

### B4 `pet_memory.gd`（约 970 行 → 790）—— B4.1/B4.2 完成，**B4.3 按需豁免记账**
   - [x] **B4.1** 提示词常量与「给提示词用」那层 → `pet_memory_prompt.gd`（209 行）：
     `context_block` / `profile_lines` / `working_lines` / `profile_text` / `since_text` /
     `working_text` + 三个模板（FACT / OBSERVE / WORKING）+ `parse_json_*`（"安静解析"那套）
   - [x] **B4.2** 分层与遗忘 → `pet_memory_forget.gd`（99 行）：`layer_of` / `forgetting_strength` /
     `retrieval_weight` / `retention` / `retention_of` / `decay` / `prune` / `consolidate` / `stats`
     —— 顺带把 `enum Layer` 的**真源**挪过去，pet_memory 用 `enum Layer { CORE = MemForget.Layer.CORE, … }`
     派生（`PetMemory.Layer.CORE` 是 probe_memory 在用的写法，不能断；实测解析期与运行期都成立）
   - [x] **B4.3** 收口复核 **+ 豁免记账**：966 → **790 行**。豁免理由见 CONVENTIONS.md 的清单：
     剩下的是"一条记忆"的完整链路（写入打分 → 检索 → 遗忘 → 存盘），再切会把同一条链路断成三处
   - 验收：解析（7 个文件）✓ / **probe_memory --offline 92/92** ✓（分层 / 遗忘曲线 / 清理都在里边）/
     冒烟开局那行 `[桌宠] 记忆：30 条（核心 0 / 重要 0 / 常规 30），档案 0 项` 走的正是新 `stats()` ✓ /
     导出 13:33 ✓
   - ⚠️ **必须记下的坑**：新模块里 `mem` 是**弱类型**（故意不标，否则循环 preload），
     于是 `var x := mem.xxx()` 这种**类型推断会直接解析失败** —— 必须写 `var x: Array = mem.xxx()`。
     B4.1 连踩三处（`recalled`、两个 `t`、`gap`），全被解析阶段拦住（探针那 3 项 FAIL 也是同一个根因）
   - 若以后不接受豁免：再切两刀即可进 500 —— 「情绪与重要度打分」（`analyze_mood` / `mood_name` /
     `score_importance` 及三张表，约 90 行）→ `pet_memory_mood.gd`；「检索」（`retrieve` / `match_score` /
     `expand_query` / `worth_remembering` 及 `_rank_*` 小工具，约 250 行）→ `pet_memory_recall.gd`

### B5 `pet_shell.gd`（约 1120 行 → 554，进行中）
   - [x] **B5.1** 复核 + 切法：**结论和作业单写的不一样** —— 前 667 行里，**53-627 行是一整段内嵌的
     PowerShell 脚本源码**（577 行，纯数据）。不先把它挪走，怎么切逻辑都进不了 500 行。
     所以先做了这一刀：→ **`pet_shell_ps1.gd`（588 行）**，pet_shell **1123 → 554 行**
     - 手法：用 .NET 的字节级读写（显式 UTF-8 **无 BOM**）做**机械切分** —— 577 行 PowerShell
       手工转录风险太大，机械切分反而是"逐字节相同"的
     - 验证：解析 ✓（三引号字符串完不完整，解析期就能看出来）/ 冒烟 ✓ /
       **落盘的 `pet_shell_window.ps1` 没被重写**（mtime 还是 9/21）✓✓ —— `_ensure_ps1()` 只在
       内容变了才写，所以"没重写"正好证明搬过去的文本与原来**逐字节相同**
   - [x] **B5.2** 命令通道 + 看门狗 → **`pet_shell_watch.gd`（247 行）**：常驻子进程的生死
     （拉起 / 每 0.5 秒探活 / 死了重拉 / 退出收掉）+ 三条小文件通道（state / cmd / want）
     —— pet_shell **554 → 384 行**（**进 500 了** ✓，不用豁免）
     - 共享字段（`fullscreen` / `fullscreen_aware` / `tray_icon` / `popup_open` / `top_wish`）
       **留在 pet_shell**（desktop_pet 在读它们），模块通过宿主对象读写
     - 顺手加了 `watcher_pid()` 访问器：`tools/probe_tray.gd` 原来直接 `get("_watcher_pid")`，
       字段一搬它就**卡死**（超时被强杀，只打出 A 段标题）—— 教训：工具不该摸私有字段，
       而"搬完忘同步探针"这类事以后一律靠 `probe_*` 当场抓（这次就是 probe_tray 抓的）
     - 验收：解析 ✓ / **`probe_tray` 全部通过** ✓（辅助进程活着、命令行四项齐、图标字节一致、
       toggle 往返、恢复后 TOOLWINDOW 仍为 True）/ 冒烟 ✓ / 状态与意愿文件时间戳都是当场
       （13:42:02、13:42:03 = watcher 真在写心跳）✓ / 导出 13:42 ✓
   - [x] **B5.3** 「开机自启动」+「隐藏任务栏」+「跑一次 PowerShell / reg」合成一个
     **`pet_windows.gd`（237 行）** —— pet_shell **384 → 215 行**（整个 B5：**1123 → 215**）
     - 顺带清掉 pet_shell 里已经无用的东西：`RUN_KEY` / `RUN_NAME` / `RUN_NAME_LEGACY` /
       `MISSING_MARK` / `PS1_FILE` / `_ps1_path`（连同"值名为什么必须是 ASCII""为什么不能过一层
       .cmd"那几条教训一起搬进新模块 —— 注释一条没丢）
     - 验收：解析（5 文件）✓ / **自启动读取链**（一次性探针，全只读）✓ ——
       `refresh()` 从注册表读出 `autostart_on=true`、`autostart_status()=已开启`、
       **`read_registered_command()` 把带中文路径的命令原样读回来**（证明 `_ps` / `_b64` /
       `_ensure_ps1` 这条 PowerShell + base64 链路搬完照样对，没变乱码）✓ /
       **`probe_tray` 全过** ✓ / 冒烟 ✓ / 导出 13:46 ✓
   - [ ] **B5.4** 只剩**手点**那一下（自动部分都过了）：菜单里的「开机自启动」开关一次、
     「隐藏任务栏图标」开关一次、托盘图标开关一次 —— 菜单文字和托盘图标要你亲眼看

### B6 `desktop_pet.gd`（2525 → **2361 行**；**永远 ≤500 做不到，B6.4 已写好豁免记账**）✓ 完成
   - [x] **B6.1** 「被摸到的反应」→ **`pet_touch.gd`（94 行）**：`react` / `on_line` / `on_overflow`
     —— desktop_pet **2525 → 2483 行**
     - ⚠️ **复核改写了作业单**：它标的 [2203-2472] 那 270 行**不是一件事** —— 里面是被摸（~67 行）
       和 偷看屏幕（~137 行）+ 摄像头（~50 行）+ 自言自语（~17 行）混在一起
     - 两样跨不过来的东西在 `setup()` 传进去：`PROMPT_TOUCH` / `EMOTE_NAMES`（弱类型引用取不到
       脚本常量）；`State.IDLE` 用宿主开的一行口子 `go_idle()`；mood 模块的常量直接
       preload `pet_mood.gd` 取（平级模块，不成循环）
     - 验收：解析 ✓ / **摸她那条链的一次性探针** ✓（摸头 ×7 + 摸胸 ×3 + 再连摸 10 下，
       打出「被摸烦了 → 已记进长期记忆」「摸得太频繁（一分钟内到 8 下）→ 她主动开口」——
       证明 宿主壳 → 模块 → pet_mood 判定 → 信号 → 宿主壳 → 模块 这条往返全程跑通）/
       探针把记忆指到临时文件（不拿真记忆当实验品）✓ / 冒烟 ✓ / 导出 16:52 ✓
   - [x] **B6.1b** 偷看屏幕 + 看摄像头 → **`pet_peek.gd`（204 行）**：`check_peek` / `check_camera` /
     `peek_and_comment` / `peek_screen` / `camera_look` / `camera_shot`
     —— desktop_pet **2483 → 2336 行**
     - 两条提示词（`PROMPT_PEEK` / `CAMERA_QUESTION`）和 `PEEK_RETRY_SEC` **跟着模块走**，
       宿主那三份副本删了（留在原处只会变成"改了没反应"的副本）
     - 六个壳一个都不能少：**tools/probe_chat_ui.gd 用 `pet.call("_peek_screen")` /
       `pet.call("_camera_look")` 这类写法直接打它们**，名字一改探针就哑（probe_camera 同理）
     - `camera_look` / `camera_shot` 是协程 → 壳写成 `await _peek.xxx()`，协程语义不变
     - 验收：解析（4 文件）✓ / **probe_chat_ui 的 E 段**（`_peek_screen` → data URL 解码
       142252 字节、是 JPEG）✓、**F 段**（带图一轮真收到回复）✓、**G 段**（摄像头走平台专属提示
       「唔…我这台机器上用不了摄像头诶。」）✓ / 冒烟 ✓ / 导出 17:03 ✓
     - ⚠️ 一处**不属于本次改动**的观察：probe_chat_ui 在 E/F/G/H 全过之后，卡在它自己的收尾
       第 336 行 `pet.call("_sync_toggle_menu")` —— 没打出"存档已还原"、也没走到 `quit()`，
       stderr 无脚本错误。那条链路本次没碰；要查可以单独理
   - [x] **B6.1c** 「自言自语」**评估：留着** —— 只有 17 行，且和"主动说话"那几个 timer / 四档频率
     缠在一起（`_idle_talk_timer` / `_rand_talk_delay()` / `_ask_proactive()`），单独成模块反而更碎
   - [x] **B6.2** 「长期记忆」区块 **评估：无需搬（前提已满足）** —— 复核那一段（1747-2020）现在
     **全是聊天接线**（收流 / 回执 / 离线判定 / 状态同步 / 人格刷新），**没有**"纯提示词 / 纯数据"；
     那些早就在 `pet_memory_flow.gd` 里（`SYS` / `MIN_USER_CHARS` / `should_extract`）
   - [x] **B6.3** 「设置面板桥」**评估：不搬**，三条理由 —— ① 它就是 `SETTING_VARS`
     （@export ↔ 面板键的**映射表**），和"@export 必须留宿主"是同一件事，拆开等于两处要同步；
     ② 它要读 shell / memory / `_say` / `_set_chat_focus` 这些宿主状态，本质是编排；
     ③ 硬搬进 `pet_settings.gd` 会把它顶到 650 行以上（那个文件现在 481 行）
   - [x] **B6.4** 文件头已写清「体量豁免」（放在开头总谱说明之后）：留下的是 ① **87 个 @export**
     （实测数，原来索引里写的 84 已过时、顺手改正）② 装配顺序 ③ 每帧推进的唯一一处
     ④ 一批接线壳；并列出行为块都搬去了哪些模块、以及 B6.2 / B6.3 两次"评估后不搬"的原因

## 一级 C：收口与验收（每条二级任务的验收标准）

### C1 验证阶梯（2026-09-23 全量跑过一遍）
- [x] **C1.1** 解析：本轮改动过的 **34 个文件**（23 个模块 + 11 个探针）全部通过 `--check-only` ✓
- [x] **C1.2** 离线自检：`probe_memory.gd -- --offline` **92 项全绿** ✓
- [x] **C1.3** 冒烟：真窗口 10 秒，stderr 干净 ✓
- [x] **C1.4** ✓ **补跑通过**：用户把 key 重新给了一份、已写回 `user://pet_chat.cfg` 的 `[ai] key`
  （url / model / vision_key 都不用填 —— 前两个回落脚本默认值，视觉那条的注释写着"留空 = 复用
  chat_access_key"）；`probe_live` **全部通过**（警告 1 条，是那条老警告"模型那组没换上来，不算 bug"），
  开局打出 `后端可达 ✓｜模型=deepseek-flash｜地址=https://api.deepseek.com`
- [x] **C1.5** 导出：`pet.exe` 重导 ✓（**17:18**）

### C2 索引同步（每次结构性改动后三样一起更新）
- [x] **C2.1** 对上了 ✓：磁盘 36 个脚本 = 地图 36 条（+38 个探针，共 74 条）；
  本次新加的 **17 个模块**逐个在地图里都能找到；desktop_pet 文件头也点名了 `pet_touch` / `pet_peek`

## 一级 D：目录分层 → **做了** ✓（2026-09-27）

### D1 `scripts/` 分子目录 ✓ 完成
- [x] **D1.1** 方案落地：`ai/` **16 个** · `ui/` **5 个** · `sys/` **7 个** · `body/` **8 个** ·
      `desktop_pet.gd` **留根**（场景按 path 引它）。37 个文件**不多不少全有归属** ✓
- [x] **D1.2** 代价实测（比作业单估的**大三倍**）：`res://scripts/…` 引用 **74 处**
      （73 个 .gd + 1 个 .tscn），其中 67 处指向要搬的名字 → 脚本化改写（**保留每个文件原有的
      BOM 状态**），改完 25 个文件。另外两件当年没算到的好消息：
      ① `desktop_pet` 留根 ⇒ **场景文件一处都不用改**；
      ② `<项目目录>\{scripts,tools,scenes}` 是**链接**（同一份目录）⇒ 不存在同步问题
- [x] **D1.3** 重跑 C1 全部：解析 ✓ / 冒烟 12 秒**零报错**（所有模块都会被 preload，路径错必炸）✓ /
      `probe_memory --offline` **92/92** ✓ / `probe_live` 四条路**全过** ✓ / 导出 **09:51** ✓。
      顺带修 `probe_map.gd`：改成**递归**扫（否则 36 个文件里 35 个会从地图上消失），
      并把 README(24 处) + CONVENTIONS(2 处) 里的老路径一起改掉

---

## 一级 B 补充：自检脚本也守同一套规矩

### B7 `tools/probe_memory.gd`（621 行 → **496 行**）✓ 完成
   - [x] **B7.1** 「她那边」的几组 → **`tools/probe_memory_prompt.gd`（173 行）**：
     7.5 快速回答的候选句 / 7.6 偷看提示词 / 7.8.x（提示词缓存 · 实时时间 · 距上次说话 ·
     缓存瘦身）/ 7.5.1「她自己先开口」的 `%%` 拆分 / 8 主动说话频率档 —— 一共约 140 行
     - 手法：新模块自带一个**转发用的 `_check()`**（转回主探针 —— 那里才管 `[OK]/[FAIL]` 与计数），
       于是搬过去的检查**逐字不用改**，只补了几个就近 `load()`
     - 一处必须补的坑：`pet_script` 原来声明在 7.5 那段里，那段搬走后 7.10 与频率档就没了它 →
       在 7.6 那个空位重新声明（并注明为什么）
     - 输出顺序变了（那几组现在排在 7.5 那一行的位置一起跑），但检查项**一个没少**：
       `probe_memory --offline` 仍是 **92 项全绿** ✓
     - 验收：解析 ✓ / 92/92 ✓ / 逐组抽查搬走的检查都还在跑（快速回答、偷看提示词、缓存前缀、
       实时时间、距上次说话、缓存瘦身、`%%` 拆分、频率档）✓

---

## 进度记录

| 日期 | 任务 | 结果 |
| --- | --- | --- |
| 2026-09-23 | A1.1 + A2.1 | 宪法 + 全仓地图落地；`probe_map.gd` 首次输出 19 个脚本 / 10127 行 |
| 2026-09-23 | A2.2 + A2.3 + **B1.1** | 地图会标 ⚠ 超标文件；README/主脚本头部指向地图；`Conn` → `pet_conn.gd`（pet_chat 851 → 745），probe_live 四条路全过，pet.exe 已重导（12:33）|
| 2026-09-23 | **B1.2** | 流式解析 → `pet_sse.gd`（165 行，pet_chat 745 → 676）；探针补 5 项（probe_memory 92/92）；白盒探针注入点跟着改（probe_chat_stream 全绿）；probe_live 四条路全过；pet.exe 已重导（12:43）|
| 2026-09-23 | **B1.3（部分）** | 429 重试 → `pet_retry.gd`（70）+ 一次性请求 → `pet_once.gd`（120）；pet_chat **676 → 599**（**还差 ~100 行**，B1.4 继续）；探针同步打桩点后 92/92；probe_chat_stream / probe_live 全绿；pet.exe 已重导（12:54）|
| 2026-09-27 | **D1 目录分层（作业单全部完成）** | `scripts/` 分四个子目录：`ai/` 16 · `ui/` 5 · `sys/` 7 · `body/` 8，`desktop_pet.gd` 留根。**实测代价比作业单估的大三倍**：`res://scripts/…` 引用 **74 处**（67 处要改，脚本化改写并保留各自 BOM 状态，动了 25 个文件）；两个没算到的好消息：desktop_pet 留根 ⇒ **场景文件一处没改**；`<项目目录>\{scripts,tools,scenes}` 是**链接**（同一份）⇒ 无同步问题。顺带修 `probe_map.gd` 改成**递归**扫（否则地图会少 35 个文件）+ README/CONVENTIONS 里 26 处老路径。验收（重跑 C1 全套）：解析 ✓ / **冒烟零报错** ✓ / **probe_memory 92/92** ✓ / **probe_live 四条路全过** ✓ / 导出 **09:51** ✓ / 地图递归列出 37 个脚本（带子目录前缀）✓ |
| 2026-09-27 | **B7（完成）** | 「她那边」的几组自检（快速回答候选句 / 偷看提示词 / 提示词缓存 / 实时时间与距上次说话 / 缓存瘦身 / `%%` 拆分 / 频率档，约 140 行）→ **`tools/probe_memory_prompt.gd`（173 行）**；`probe_memory.gd` **621 → 496**（进 500 ✓）。手法：新模块自带**转发用的 `_check()`**，搬过去的检查逐字不用改；`pet_script` 那个声明在原 7.5 段里、跟着搬走会影响后面的 7.10 与频率档 → 补在 7.6 空位并注明。验收：解析 ✓ / **`probe_memory --offline` 仍 92 项全绿** ✓（检查项一个没少，只是输出顺序变了）/ 逐组抽查都在跑 ✓ |
| 2026-09-27 | **三件事：聊天记录可滚动 / 频率随机 / 四次不理就闭嘴要哄** | ① **聊天记录**：面板高度固定（96px）但记录原来**只留 `chat_log_lines`（3）行**、超出直接丢 ⇒ 用户报"聊天后不显示在聊天记录"。改成 `ScrollContainer` + 保留 `CHAT_LOG_KEEP=60` 行（滚轮/拖滚动条往回翻，新行自动滚到底，`call_deferred` 避开协程），每行仍按 `CHAT_LINE_MAX=24` 截断；设置项改叫"聊天框显示几行（记录可上下翻）"。② **主动说话间隔随机**：原来均匀分布（300~900s）一看就是机器，改成 `pow(randf(),1.7)` 偏斜 + 15% 概率抽 1~2 倍上界的长尾 ⇒ 实测 300~1800s、中位 540、56% 落在短半区。③ **连续 4 次不理就生气闭嘴**：`pet_mood` 加 `SULK_MAX=4` / `giving_up` 信号 / `is_muted()`，`tick()` 到顶只说最后一句（`LINES_GIVE_UP`）然后闭嘴，宿主 `_check_self_talk` 问 `is_muted()` 不再开口；菜单新增「**哄哄她**」（ID 35 → `_soothe_her`，走 `_soothe` 薄壳 + `LINES_SOOTHED`），聊天/摸头/喂食本来就会 soothe。⚠️ 探针抓到自己两处旧封顶残留：`bump()` 还封在 3.0（到不了 4，`is_muted` 永远 false）、摸胸那条 `minf(3.0,…)` 在委屈度已 3.5 时**会把气拉低** ⇒ 前者改 `SULK_MAX`，后者改 `maxf(_sulk, minf(SULK_MAX-1.0, …))`（摸她不该让她闭嘴，也不该消气）。⚠️ 另：`probe_offline` 报 6 项没过，查出是**探针自己的竞态**（开局那次自动探活从第一帧就发，几百毫秒后返回 true，把手工扳的"离线"覆盖掉 ✗）⇒ 探针改成"先等首次探活落地再扳离线"，之后**全部通过** ✓。验收：解析 ✓ / `probe_memory --offline` 94/94 ✓ / `probe_offline` 全部通过 ✓ / 三件事的确定性探针全绿 ✓ / 冒烟 ✓ / **导出失败（pet.exe 被占用，等你关掉再导）**|
| 2026-09-27 | **修"聊天框会卡丢"（%% 候选外漏）** | 用户截图：普通打字聊天里，聊天气泡下多出一行 `%% ["你行你上啊",…]`。根因三处叠加：① `%%` 的拆分**只在"她自己先开口"那条路做**（`desktop_pet._on_chat_token` / `_on_chat_replied` 都靠 `_reply_opts_mode` 判断）⇒ 普通聊天里来了候选就整段留下；② 模型会**照着历史学**这个格式 —— `pet_chat._finish` 把带 `%%` 的原文直接写进 `_history`，等于每轮都在示范；③ 实时流那条也一样，候选会跟着冒进气泡。修四处：`_on_chat_token` / `_on_chat_replied` **不管哪条路都在 `%%` 处切**（跨 token 到达也切得干净）；拆出来的候选**直接当按钮**（不浪费，还省一次"让模型编候选"的请求；chat 那条照旧受 `quick_chance_chat` 概率管）；**根因**在 `pet_chat._finish` → 写历史前 `_strip_options()` 去掉候选那段；分隔符收成单一真源（`const OPTIONS_MARK` 定义在 pet_chat，宿主用别名）。验收（确定性探针，不花请求）：历史清洗 `'她刚才说了句话\n%% [...]' → '她刚才说了句话'` ✓ / 聊天框最后一行 `她：她刚才说了句话` 不含 `%%` ✓ 且候选变成按钮 ✓ / 实时流（`%%` 拆成两个 token）气泡只到 `你好呀` ✓；记忆存档 0 条含 `%%` ✓ / `probe_memory --offline` 94/94 ✓ / 冒烟 ✓ / 导出 **22:46** ✓。**注意**：聊天记录与模型历史都只在内存里 ⇒ 重启即自愈（旧运行里留下的 `%%` 示范才会停止）。**紧接一条**（用户自己判断出"文字太多给聊天框卡掉了"）：机制是聊天面板是**固定高度**（`offset_top=-104`/`bottom=-8` ⇒ 96px 的底部卡片），而里面的 `_chat_log_label` **只开了 autowrap、没开裁剪** ✗ —— 长回复折行后高度没人管，直接**画到卡片外面**（截图里那几行确实跑到白卡片外了）。修：① 标签加 `clip_text` + `OVERRUN_TRIM_ELLIPSIS` + `max_lines_visible = chat_log_lines`；② `_refresh_chat_log` 每行先按 `CHAT_LINE_MAX = 24` 截断加省略号（说话人前缀在开头，截了也认得出是谁说的）；③ 顺手补上占位文案漏掉的右括号。验收（确定性探针）：clip_text ✓ / max_lines_visible=3 ✓ / 省略号 ✓ / 面板 96px ✓ / 超长行截到 25 字且不再出卡片 ✓；`probe_memory` 94/94 ✓ / 冒烟 ✓ / 导出 **22:50** ✓ | 逐个面查"还有没有各算一套"。**已融合** ✓：时间口径只有 `hours_since` 一处（喂遗忘曲线 / 重排时间分 / 年龄分档）；存盘只有 `pet_memory.gd` 一个主人；`Item` 字段只有 memory + forget 写；年龄显示只走 `rough_age`。**抓到并修掉一处真问题** ✗："上次说话"有**两个来源、两套格式** —— 记忆那边 `since_text()` 用持久化的 `memory.last_chat`、人设那边 `_gap_text()` 用宿主的 `_last_talk_ms`（只在本次运行里数），同一段提示词里能同时出现"上次和主人说话是 2 小时前"和"距上次说话 5 小时"（探针把两行一起打出来验的）。修法：① `pet_memory_forget` 新增 `gap_phrase()`（数字一套）；② `since_text` / `_gap_text` 都改调它；③ 宿主 `_context_for` 的 `gap_min` 改从 `memory.last_chat` 算（没开记忆才回落会话计时），并给 `pet_memory` 留 `hours_since` 壳免得宿主自己写时间戳减法。修后实测两行一致：`2.28 小时 → "2 小时前" / "距上次说话 2 小时"` ✓。**还剩一处结构问题**（无 bug）：打分函数分居两文件 —— `analyze_mood`/`mood_name`/`score_importance`/`worth_remembering` 在 `pet_memory.gd`（863 行，B4.3 豁免在案），而 `layer_of`/`retention`/`decay` 在 `pet_memory_forget.gd` ⇒ 可选：抽 `pet_memory_score.gd`（~180 行）让"打分"彻底一处，pet_memory 降到 ~680（仍超 500，但更近）。验收：解析 ✓ / `probe_memory --offline` **94/94** ✓（"距上次说话 分钟/小时各一档"两条照旧通过）/ 冒烟 ✓ / 导出 **22:25** ✓ | 用户报"她主动说话与我正在干的事不一样"，查出两段成因：① 抓屏是**桌面级**（`DisplayServer.screen_get_image`），独占全屏 / 带反作弊的游戏不在合成里 → 她只拿到桌面，而用户桌面铺满文件夹图标 ⇒ 视觉模型读出"在整理文件"（我把那张图存下来给自己看过，确认**图是真的、她没撒谎**）；② 那批偷看留下的"现在时"文字记忆每轮都发给她。**改动**：`pet_peek.gd` 新增 `foreground_text()`（`user://pet_fg.ps1` + 结果写文件读回 —— **不能**把 DllImport 塞命令行：三层引号剥皮会被咬，实测 Add-Type 报"不存在 user32"；也**不能**收 stdout：会按 ANSI 页解码把中文标题弄乱）、`wants_proactive_peek()`、`proactive_peek_prompt()`（带前台窗口的提示词，并明说"画面和它对不上就别硬猜"）；`desktop_pet` 加 `proactive_peek_enabled`（**默认开**）与 `proactive_peek_chance`（0.35），`_ask_proactive` 里概率性抓图 + 把 `_last_origin` 标成 `peek`（记忆按"她看到了"走选择性抽取）；菜单加「主动说话时先看一眼屏幕」（ID 34）+ `sync_toggles` 加第四个参数（只有一处调用点）。⚠️ 自己写的探针抓到两个错：**读错字段**（读 `@export` 而不是运行时 `_proactive_peek_on` ⇒ 菜单关掉不生效）、探针没等探活完就断言"没发出去"。另修：`_host._powershell()` 不存在 → 走宿主公开的 `shell.powershell()`。验收：解析 ✓ / 前台窗口真读到 `PvZ2: Gardendless`（577ms）✓ / 链路探针（开关→概率→抓图 297KB→提示词含窗口名→`_chat_streaming=true`、`_last_origin=peek`）✓ / `probe_memory --offline` **94/94** ✓ / 冒烟 ✓ / 导出 **19:29** ✓。**追加一处**（用户紧接着问"选项是不是卡没了/主动说话变频繁了吗"）：实测"主动开口 + 瞥一眼"这条路**按钮正常**（回复后 2.2 秒出现、两秒后还在、候选还贴在屏幕上）；同时发现自己引入的隐患 —— `origin` 要同时伺候"记忆按哪条记"和"按钮挑哪一组"两个消费者，标成 `peek` 会让模型没给 `%%` 时按钮摆出偷看那组（"看够没？"）⇒ 拆出 `_opts_kind_override`（记忆仍按 peek；按钮按 proactive）。另：实测本机主动说话间隔 **5~15 分钟**（档位=1 普通，`self_talk_after=(300,900)`），频率逻辑本轮未动。导出 **19:42** ✓。**再追加**（用户接着报"她识别到我在挑壁纸，而我在挂机窗口游戏"）：把 `context_block` 打出来一看就明白了 —— 那批活动事实被我加了**绝对日期**，而它们恰好是**当天**记的 ⇒ "9月27日主人正在挑壁纸（你印象很深）" 读起来等于"他今天正在挑壁纸" ✗（我上一轮那处"加日期"的修法对**同日**条目起了反效果）；而查询"游戏"一条都捞不到（她根本没有游戏相关记忆）。修三处：① 读出端 `_date_tag` 近两天改用**相对说法**（"（今天早些时候）"/"（昨天）"，更早才写日期）；② 写入端 OBSERVE/FACT 提示词加第 5/6 条 —— **别记"他此时此刻正在做什么"这种一时之事**（第二天就过期、而她会一直照着说；"他此刻在干嘛"另有渠道=偷看那一眼）；③ 数据侧把 2 条里的"正在"去掉（只改这两个字，备份 `bak-20260927-1948`）。复看效果：`…（今天早些时候）（你印象很深）` ✓。验收：解析 ✓ / `probe_memory --offline` 94/94 ✓ / 冒烟 ✓ / 导出 **21:58** ✓。⚠️ 过程记录：写临时探针时**三次**把中文引号套进 GDScript 字符串（都在 `tools/_tmp_*.gd`，没碰产品代码）。**再追加**（用户要求"加入大概时间，并且融合原装的记忆打分系统"）：① `pet_memory_forget` 新增 **`hours_since()`** —— 全仓唯一算"多久以前"的地方，同时喂 ①遗忘曲线 `retention` ②重排的 `time_score`（pet_memory.gd 原来自己手算一遍，已改）③给模型看的年龄 —— 口径只有一份（今天的 bug 就是显示侧自写一套导致的）；② 新增 **`rough_age()`**：粗粒度分档（刚刚／今天早些时候／昨天／前天／前几天／上周／前阵子／≥1 个月给具体月日）；③ `pet_memory_prompt._date_tag` 改成转调 `rough_age`（不再自己写日期逻辑）；④ 数据侧去掉 3 条里"与记录日重复"的日期前缀（`9月27日主人挑壁纸…` → `主人挑壁纸…`，另一个备份 `bak-20260927-2205`）。验收：分档表 8 档全对 ✓ / 融合点 `hours_since=3.00 → retention=0.810 → 今天早些时候` ✓ / `probe_memory --offline` 94/94 ✓ / 冒烟 ✓ / 导出 **22:08** ✓ |
| 2026-09-27 | **用户反馈的一轮修复（5 件）** | ① **时间/记忆没发给主聊天**：`_chat.context_provider` 从来没接上 ✗（只有 `_vision` 接了）⇒ 她既不知道时间、也记不得主人，时间"停在 10 点"；一行修好，`probe_memory_prompt` 的"时间/记忆不在系统提示词里"自检仍 ✓。② **UI 随桌宠变小**：`set_scale_percent` 原来缩的是**窗口**（`project.godot` 是 `stretch=canvas_items` ⇒ 画布连同 UI 一起缩）；改成**窗口不动、只动相机取景**（`pct>1` 才放大窗口并把 UI 层反向缩回 100%）—— 实测 0.75 档：窗口仍 330×470、相机取景 ×1.33、UI 层 1.0 ✓。③ 活动范围 `nearby_radius` 220 → **140**（含用户存档里的值）。④ **记忆时间口径**：三个提示词都带上"今天的日期"并明令把"今天/昨天"换算成具体日期；读出端给旧记忆标 `（9月22日）`；她的原话不再当"关于主人的事实"存（只在没开 AI 整理时兜底）；写入端另加"别写成他现在正在做什么的口气"（否则几小时后她自己会当成此刻）。数据侧按用户选的"只改文字、一条不删"改了 **18 条相对时间 + 3 条活动事实**（各留备份）。⑤ **检索"越滚越牢"**：兜底固定取最重要的 5 条 + 每次被想起 `access_count+1` ⇒ 她反复念同一件事（用户报"一直在强调看壁纸那一瞬间"）；改成**弱命中只给 1 条（`FALLBACK_RECALL`）+ 刚送过的打 0.05 折 + 兜底按"没刚送过"优先**。⚠️ 自检在这轮抓到我自己两个错：把"弱命中就不召回"当修法 ✗（`probe_memory` 立刻报「我平时爱喝什么」找不回「冰美式」）→ 改成**只限条数、不砍召回**；`_rank_by_match` 返回的是 **Item 列表**，我按 `semantic[0]["score"]` 取分 ✗ → 运行时错误让 `retrieve` 整体返回空 → 两个探针同时抓到。新增 2 条自检（检索节制 / 检索轮换），`probe_memory --offline` **94/94** ✓。另记：抓不到**独占全屏 / 带反作弊**的游戏（实测《暗区突围：无限》+ ACE）—— 桌面级抓屏的固有限制，已写进 README，并让提示词"只说你真看到的、别猜"。导出 **17:28** ✓（两次被占用挡住：得先退掉正在跑的 pet.exe）|
| 2026-09-23 | **密钥加密（用户额外要求）** | 新增 `pet_secret.gd`：用引擎自带的 `FileAccess.open_encrypted_with_pass()`（AES-256 + SHA-256 派生口令，口令 = 机器标识\|用户名\|机器名\|盐）把 chat / vision 两个 key 存进 `user://pet_secret.dat`；**配置文件里那两项恒为空串**（`[ai] key` / `vision_key`）—— 配置文件从此可以安全截图 / 分享 / 误提交。一次性迁移写在 `_load_chat_config` 里（读到老明文 key → 存进加密文件 → 清掉配置里那项 → 落盘）。实测：迁移后配置 **51 字节、无 key、无 `sk-`** ✓；加密文件 92 字节、里面搜不到明文 ✓；**重启第二个宿主读到同一个 key** ✓；`probe_live` **全部通过** ✓（真调 API 成功）。⚠️ 过程中犯两个错，一并记下：① **凭记忆写 `AESContext.get_final()`**（不存在）→ 加解密还没验通就跑了迁移 → 真配置里写进一个解不开的坏值 ✗ —— 这**违反了我自己刚写进 CONVENTIONS 的"先验证再动真文件"**，已复原重做；② `Crypto.encrypt()` 要的是非对称 `CryptoKey`、不是密钥字节（又猜错 API）→ 改成先跑 `ClassDB.class_get_method_list` 校对再实现。两条都写进 CONVENTIONS.md（含"别猜引擎 API"那条） |
| 2026-09-23 | **C1 + C2（全量验收）** | C1.1 解析 **34 个文件全过** ✓ / C1.2 `probe_memory --offline` **92/92** ✓ / C1.3 冒烟干净 ✓ / C1.5 导出 **17:18** ✓ / C2.1 索引对上 ✓（36 脚本 + 38 探针 = 地图 74 条；新加 17 个模块都在）。**C1.4 `probe_live` 没过，原因是一次真实事故（记在这儿备查）**：`probe_chat_ui.gd` 的收尾调的是 `_sync_toggle_menu`，而该方法早改名成 `_sync_menu_toggles` → `Object.call()` 打不存在的名字让协程**静默死掉**（不报 SCRIPT ERROR）→ 探针那句"还原存档"没执行 → 它临时写过的 `user://pet_chat.cfg` 留在原地。那份 cfg 是**全仓唯一一份**（`chat_access_key` 的 @export 默认是空串、场景文件里也没有）→ **用户的 AI 密钥丢了**。已修：① 探针改成"改完**立刻**还原"，再做别的；② 用对方法名；③ 两条教训写进 CONVENTIONS.md（碰真文件时备份/还原必须挤在一起；改私有方法名要全仓搜一遍 `pet.call("…")` 这类打桩点）。修好后重跑 `probe_chat_ui`：**能走到自己的收尾了**（"H 存档已还原" + "菜单勾选已同步回去"），未再造成新破坏。⇒ **已解决**：用户提供了 key，已写回 `user://pet_chat.cfg` 的 `[ai] key`（只写这一个键：url/model 回落脚本默认值，视觉那条留空即复用 chat 的 key）→ **C1.4 `probe_live` 补跑全部通过** ✓，`C1` 五步齐了 |
| 2026-09-23 | **B6.1c/B6.2/B6.3/B6.4（B6 完成）** | 三件都是"复核后决定"：**B6.1c** 自言自语（17 行）留着 —— 和主动说话那几个 timer 缠在一起；**B6.2** 长期记忆那段**没有**纯提示词/纯数据可搬（它们早在 `pet_memory_flow.gd`，剩下全是聊天接线）；**B6.3** 设置面板桥**不搬**（`SETTING_VARS` 是 @export↔面板键的映射表，拆开就两处要同步；它还要读 shell/memory/_say；硬搬会把 pet_settings.gd 顶到 650+）。**B6.4** 把"体量豁免"写进 desktop_pet 文件头：留下 87 个 @export（实测；索引里原来写 84 是过时的，顺手改正）+ 装配顺序 + 每帧推进 + 接线壳，并列出行为块都搬去了哪些模块、两次不搬的理由。desktop_pet **2336 → 2361**（+25 行全是那段豁免说明）。验收：解析 ✓ / 冒烟 ✓（只改注释，未重导）|
| 2026-09-23 | **B6.1b（偷看 + 摄像头）** | → `pet_peek.gd`（204 行）：`check_peek` / `check_camera` / `peek_and_comment` / `peek_screen` / `camera_look` / `camera_shot`；desktop_pet **2483 → 2336**（累计 2525 → 2336）。三条常量（`PROMPT_PEEK`/`CAMERA_QUESTION`/`PEEK_RETRY_SEC`）随模块走、宿主副本删掉；六个壳必须留（probe_chat_ui / probe_camera 用 `pet.call("_peek_screen")` 这类写法直接打名字）；协程壳写成 `await _peek.xxx()`。验收：解析 ✓ / probe_chat_ui 的 **E**（截屏→data URL→142252 字节真 JPEG）、**F**（带图一轮真回）、**G**（摄像头平台专属提示）✓ / 冒烟 ✓ / 导出 17:03 ✓。**另记**：probe_chat_ui 在 E/F/G/H 全过后卡在自己的收尾 `_sync_toggle_menu`（第 336 行）没走到 quit，stderr 无脚本错误 —— 该链路本次未碰，待单独理 |
| 2026-09-23 | **B6.1（被摸到的反应）** | → `pet_touch.gd`（94 行）；desktop_pet **2525 → 2483**。复核改写作业单：它标的那 270 行**不是一件事**（被摸 ~67 + 偷看 ~137 + 摄像头 ~50 + 自言自语 ~17），所以只搬了"被摸"这一条链，其余留下并新立 B6.1b。跨不过来的东西：`PROMPT_TOUCH`/`EMOTE_NAMES` 由 `setup()` 传、`State.IDLE` 用宿主口子 `go_idle()`、mood 常量直接 preload `pet_mood.gd`。验收：解析 ✓ / 摸她那条链一次性探针 ✓（摸头×7+摸胸×3+再连摸 10 下 → 打出"被摸烦了 → 已记进长期记忆"与"摸得太频繁…→ 她主动开口"，证明往返全程通）/ 记忆指到临时文件 ✓ / 冒烟 ✓ / 导出 16:52 ✓。**顺手把反复踩到三次的两个语法坑写进 CONVENTIONS.md**（弱类型下不能 `var x := host.方法()`；脚本常量/枚举跨不过实例，三种解法）|
| 2026-09-23 | **B5.3（B5 完成）** | Windows 集成（自启动 + 隐藏任务栏 + 跑 PowerShell·reg）→ `pet_windows.gd`（237 行）；pet_shell **384 → 215**（**整个 B5：1123 → 215**）。顺带清掉 pet_shell 里已无用的 `RUN_KEY`/`RUN_NAME`/`RUN_NAME_LEGACY`/`MISSING_MARK`/`PS1_FILE`/`_ps1_path`，并把"值名必须 ASCII""不能过一层 .cmd"等教训搬进新模块。验收：解析（5 文件）✓ / 自启动读取链一次性探针（只读）✓（`refresh` 读到 autostart_on=true、`autostart_status`=已开启、**`read_registered_command` 把带中文路径的命令原样读回** → 证明 `_ps`+`_b64` 那条链路搬完照样对）/ `probe_tray` 全过 ✓ / 冒烟 ✓ / 导出 13:46 ✓。只剩 B5.4 的"手点一次菜单项"要用户亲眼看 |
| 2026-09-23 | **B5.2（命令通道 + 看门狗）** | → `pet_shell_watch.gd`（247 行）：常驻子进程生死 + 三条文件通道；pet_shell **554 → 384**（**进 500** ✓ 不用豁免）；共享字段留宿主、模块通过宿主对象读写。工具同步：`probe_tray` 原摸 `get("_watcher_pid")` → 字段一搬就卡死（超时强杀），已加 `watcher_pid()` 访问器并改探针。验收：解析 ✓ / **`probe_tray` 全过** ✓（进程活着、命令行四项齐、图标字节一致、toggle 往返、恢复后 TOOLWINDOW=True）/ 冒烟 ✓ / state+want 时间戳当场（13:42:02/03）✓ / 导出 13:42 ✓ |
| 2026-09-23 | **B5.1（复核 + 内嵌 PS1 搬走）** | 复核结论改写了作业单的假设：pet_shell 那 1123 行里 **577 行是一整段内嵌 PowerShell 源码**（数据，不是逻辑）→ 先搬它 → **`pet_shell_ps1.gd`（588 行）**，pet_shell **1123 → 554**。手法：.NET 字节级读写（UTF-8 **无 BOM**）机械切分，避免手工转录 577 行 PowerShell；验证靠解析 ✓ + 冒烟 ✓ + **落盘 .ps1 未被重写（mtime 仍 9/21）→ 证明文本逐字节相同** ✓✓。剩下 B5.2（命令通道/看门狗 → `pet_shell_watch.gd`）与 B5.3（自启动+任务栏+跑命令 → `pet_windows.gd`，两个文件合并成一个） |
| 2026-09-23 | **B4（B4.1/B4.2 完成，B4.3 豁免）** | 提示词层 → `pet_memory_prompt.gd`（209）· 分层与遗忘 → `pet_memory_forget.gd`（99，含 `enum Layer` 真源，pet_memory 派生它）；pet_memory **966 → 790**，B4.3 按作业单做**体量豁免记账**（剩下是一条记忆的完整链路：写入打分 → 检索 → 遗忘 → 存盘）。验收：解析（7 文件）✓ / **probe_memory --offline 92/92** ✓ / 冒烟开局 `记忆：30 条（核心 0/重要 0/常规 30）` 走的正是新 `stats()` ✓ / 导出 13:33 ✓。坑：新模块里 `mem` 是弱类型（防循环 preload）→ `var x := mem.xxx()` 推断直接解析失败，B4.1 踩了三处（`recalled`/`t`×2/`gap`），并被探针那 3 项 FAIL 同时印证 |
| 2026-09-23 | **B3（完成）** | 采样与统计 → `pet_rig_stats.gd`（124）· 贴图/材质修整 → `pet_rig_tex.gd`（232）；pet_rig **707 → 413**（≤500 ✓，不需要豁免）。B3.2 复核后判定"剩下不只有装配"→ 再切一刀，而不是记账豁免。唯一行为改动：`_inset_tri` 的 `pet.uv_inset_texels` 改成参数 `inset`（由 `inset_uvs` 往下传）。验收：解析 ✓ / 开局日志逐项对上（567 surface 共用 1 材质、scissor 0.50、dilate 2px、UV 内缩 0.50 texel 重建 567 网格）✓ / `probe_anim_stats` "计时短于动画的动画数: 0" ✓ / `probe_texture` 前提复核 ✓ / 冒烟 ✓ / 导出 13:29 ✓ |
| 2026-09-23 | **B2.1（B2 完成）** | 改 dsh 设置文件那层 → `pet_dsh_settings.gd`（155 行）；pet_harness **540 → 464**（≤500 ✓，不用豁免）；常量改成别名（单一真源在新模块）；`swap` / `swap_back` 改成**返回**错误说明（模块不写宿主的 last_error）；残留一处 `if _settings_dirty:` → 解析失败，已修。验收：解析 ✓ / **probe_harness --offline 全部通过** ✓（"改档"那组就是它）/ **probe_harness 真机全部通过** ✓（含"放弃等待时设置文件也原样还原了"）/ 冒烟 ✓ / 导出 13:26 ✓ |
| 2026-09-23 | **B1.4（B1 完成）** | 探活 → `pet_probe.gd`（90）· 地址/请求头/请求体/messages → `pet_net.gd`（91）· token 账 → `pet_usage.gd`（47）；pet_chat **599 → 497**，**进 500 了**（不需要体量豁免）。抓到并修掉一个真回归：搬完忘把 `pet_probe.reachable_changed` 接回自己的 `reachable` 信号（`probe_offline` + `probe_chat_stream` 抓的）；另一个坑：`_get()` 撞 `Object` 内置虚函数名 → 改名 `_fire()`。全套自检通过，pet.exe 已重导（13:02）|
