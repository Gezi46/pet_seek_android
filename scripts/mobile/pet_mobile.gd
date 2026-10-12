# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends Node3D
## **手机端宿主**（Android / iOS）。桌面那套 `desktop_pet.gd` 一行都不改 ——
## 工程的入口在 `desktop_pet._enter_tree()` 第一行分流：`OS.has_feature("mobile")`
## 为真时换到本场景，之后桌面那条路完全不走（PC 上这个判断恒为 false）。
##
## ## 为什么能整块复用现有模块
## `pet_memory_host` / `pet_chat_flow` / `pet_mood_ui` / `pet_memory_flow` / `pet_rig`
## 这些模块是按**鸭子类型**认宿主的：不继承、不注册，只看"宿主身上有没有那几个字段和方法"。
## 所以本文件的核心工作就是把这两份清单实现出来。
##
## ## 宿主接口面 ①（对话 / 记忆 / 情绪，从三个模块头部的清单汇总）
##   pet_chat_flow    _chat / _vision / harness / _quick / bubble / _begin_stream_bubble()
##                    _say() / _say_local() / _push_chat_line() / _note_reply()
##                    _check_peek / _check_camera / _check_self_talk
##                    _reply_raw / _stream_shown / _reply_opts_mode / _opts_kind_override
##                    _chat_streaming / _last_origin / _offline_said
##                    _menu_mod / chat_enabled / chat_url / hibernate_when_offline
##                    _rng / LINES_OFFLINE / OPTIONS_MARK / _gpu_busy
##   pet_memory_host  memory / memory_enabled / memory_observe / _memory_flow
##                    _chat / _vision / harness / chat_persona_name / chat_system_prompt
##                    _mood / _state / _chat_streaming / _quick / _gpu_busy / _shortterm
##                    _last_origin / _last_talk_ms / _opts_kind_override
##                    vision_model / vision_access_key / chat_access_key
##                    _clip() / _quick_context()
##   pet_mood_ui      _mood / _shortterm / _peek / _touch / memory / memory_enabled / _rng
##                    _say() / _vision / _chat / _vision_ready() / _ai_busy()
##                    _peek_screen() / _begin_stream_bubble() / _refresh_persona() / _send_first()
##                    _last_origin / _chat_streaming / _cjk_font / _bubble
##                    get_node_or_null("UI/Anchor")
##
## ## 宿主接口面 ②（pet_rig 那份 —— 值必须与桌面一致，否则她的材质/机位会两样）
##   _model / _anim / _anim_face / _pivot / _camera / _character
##   _has / _action_end / _calib_aabb / _calibrated / _aabb_cache / _aabb_frame
##   _idle_anim / _ground_offset / _timer / _rng
##   fit_ratio 0.78 ｜ _scale_pct 1.0 ｜ anim_speed 0.7 ｜ texture_filter_mode 0（最近邻）
##   alpha_scissor_threshold 0.5 ｜ dilate_pixels 2 ｜ uv_inset_texels 0（2026-10-09 从 0.5 改 0）
##
## ## 手机上**明确没有**的东西（一律停用，不是假装能跑）
##   - 托盘图标 / 开机自启 / 隐藏任务栏 / 全屏检测  → 桌面 `sys/shell/*` 那整套，不建
##   - 本机 dsh（pet_harness）                     → 手机上没有 node / bin.js，harness 恒为 null
##   - 偷看屏幕（_peek_screen）                     → `DisplayServer.screen_get_image()` 在移动端
##                                                    **没有实现**（返回 null）。手机版改成"系统分享
##                                                    把图丢给她"（阶段 5），这里先明确返回空
##   - 走路（挪窗口）                               → 手机上是普通 App，散步那条链不接
##   - 摄像头（CameraServer 原生支持 ✓）            → 保留，但按阶段 2 一起接
##
## ## 落地顺序
##   1. 分流 + 宿主契约骨架                          ✅
##   2. 3D 的她：装配 rig + 相机取景 + **触摸/摸头**   ✅（2026-10-08）
##   3. 设置页 + galgame 版式的主页面                 ✅（2026-10-08）
##   4. 对话链路跑通（chat + 气泡 + 流式）             ✅（2026-10-08）
##   4.5 **她自己开口**（pet_proactive 接上手机 ✓）    ✅（2026-10-09）
##       —— 门禁：总闸 / 生闷气 / 离线 / 正忙 / 面板开着 / 气泡还在 ✓（都在模块里 ✓）
##   5. rig 启动数据**预烘焙缓存**                    ✅（2026-10-09）
##      真机冷/热两次：装配 374 ms → **44 ms**（-88% ✓），三遍指纹逐位相同 ✓
##      签名判据 / 失效重建 / 为什么不能把逐顶点数据放进签名 —— 都在
##      scripts/body/rig/pet_rig_cache.gd 头部 ✓
##      桌面那边共用同一个模块 ✓ 一起受益（它自己的日志没加这行 ✓）
##   5b. **看摄像头**（pet_peek 接上手机 ✓）                ✅（2026-10-09 真机验过）
##       —— 真身就是桌面那份 pet_peek.gd（手机只把 foreground_text 那条
##          Windows 专属的路压成"不知道" ✓）
##       设置页加了「看图模型」+「现在看一眼摄像头」两个入口 ✓；
##       看图模型**同时就是**「让她看摄像头」的开关（手机上它只有这一个用途 ✓）
##       真机上踩出来的四件事（细节都写在 pet_peek.gd 的注释里 ✓）：
##         ① Android 6+ 要在**运行时**申请相机权限（export_presets 那条只算"声明" ✓）
##         ② `set_monitoring_feeds(true)` 之后**必须先 set_format 才能 set_active**，
##            否则引擎直接报 "CameraFeed format needs to be set before activating" ✗
##         ③ Godot 4 的 CameraFeed **没有 get_texture()**；取图要走 CameraTexture
##            ——"取哪一路图像"那个成员叫 `which_feed` ✗（不是 feed_image_type），
##            而且"摊进 SubViewport 渲一帧再读回来"最稳 ✓
##         ④ 手机有**前后两个** feed（2026-10-09 用户那句点醒的 ✓）：她该看的是**前置**
##            （对着主人那张脸 ✓），不是引擎先注册的那个（实测 #0 是后置 ✗）
##            → 按位置挑，见 pet_peek._pick_feed；宿主字段是 camera_position ✓
##         ⑤ 格式表**按分辨率从大到小**排，选第 0 个（12MP 的 4608×3456）时摄像头激活成功、
##            却**一帧都不吐** ✗（CameraTexture 恒 (0,0) → 读回来全黑）→ 挑"离 1280×720 最近"那档 ✓
##            ⚠️ 判"吐帧了没"要看 **CameraTexture 的尺寸**，别信"读回来一张 720×540"——
##               那是**空画布** ✓（2026-10-09 就被它骗了一轮 ✓）
##         ⑥ 发之前先量一眼画面（纯色/全黑就不发 ✓）+ 提示词里明说"看不清就直说、别猜别编" ✓
##            起因：用户报"她瞎说话"—— 实测当时画面是**全黑** ✗，模型照着想象编成了
##            "你在看手机、杯子空了" ✓。证据图留档在 检查输出\：
##            真机_她看到的那一帧.jpg（全黑 ✗）/ 真机_修好格式后的那一帧.jpg（红糊糊 ✓ 她说得对 ✓）
##         ⑦ 取回来的图**颜色是假的**：引擎把 Y（亮度）塞在 R 通道、G/B 空着 ✗
##            （真机实测 R 均值 91.8 ／ G 0.3 ／ B 0.4）→ 直接发就是一张"**假红图**" ✗
##            （她当时那句"画面全是红的"就是这么来的 ✓，而真实颜色我们并不知道 ✗）
##            → 掰成**诚实的灰度图** ✓（缩到 480 宽再把 R 铺到 G/B ✓）
##            见 pet_peek._collapse_to_gray；提示词里也明说"可能没颜色、别硬报颜色" ✓
##         ⑧ 抓帧前要等 ~0.8 秒让**曝光/白平衡收敛**（头几十帧本来就是黑的 ✗）；
##            另外"把相机设成环境背景让引擎转 YUV"（BG_CAMERA_FEED）在这台 + GLES3 上
##            是**全黑** ✗ → 它只当兜底 ✓，正路还是 CameraTexture ✓
##            证据都在 检查输出\真机_真正发出去的那一帧.jpg（方吊顶 + 方灯，清清楚楚 ✓）
##       顺带补了两个真 bug：
##         · 记忆那三个字段（memory_ai_extract / _every_sec / _summary_every）手机宿主
##           一直缺 ✗ —— 看图说完话进记忆收尾时直接 SCRIPT ERROR（见下面字段处的说明）
##         · export_presets 漏了震动权限 →「摸她有震动」在手机上一直是哑的 ✓
##   5c. **分享收图**（系统分享把图丢给她 ✓）            ✅（2026-10-09 本地链路已验）
##       —— 手机上补上"让主人主动给她看点东西"这条 ✓（截屏那条移动端没有 ✗）
##       三段链路：安卓 GodotApp.java 收 ACTION_SEND → 写 files/share_in.jpg
##       → pet_mobile_share.gd 每秒轮询 → 解码/缩放 → 走**和摄像头同一条**发送链 ✓
##       为这一步**动了构建方式**（本项目第一次用 Gradle 构建 ✗，踩了一串坑 ✓）：
##         ① 构建模板要装：把 export_templates/<版本>/android_source.zip 解到 res://android/build ✓
##         ② **版本标记文件在 `android/.build_version`**（不是 android/build/ 里 ✗ ——
##            引擎取的是 build 目录的**上一级** ✓），内容是**模板目录名**（"4.7.2.stable" ✓）；
##            放错层次、或者写全串（…official.xxx ✗）都会报"版本信息不存在 / mismatch" ✓
##         ③ 国内下不动 Gradle 与依赖 ✗（services.gradle.org 证书校验直接挂 ✓、
##            dl.google.com 也拿不到 ✓）→ 已换成**腾讯 + 阿里云镜像** ✓
##            （见 android/build/gradle/wrapper/*.properties 与两处 repositories 的注释 ✓，**别删** ✗）
##         ④ 分享的 intent-filter 要挂在 **activity-alias** 上 ✓
##            （GodotApp 自己 exported=false ✗，挂它身上系统送不进来 ✓）
##         ⑤ 顺带查清：Gradle 包和直导包的**签名其实一样**（都是 Godot 自带调试证书 ✓）——
##            装机被拒只是手机上的确认框没点到 ✗，不是签名问题 ✓
##       ⑥ **清单注入这条路最绕，踩了三个坑（真机验过 ✓，别再走回头路）**：
##            a. Godot 导出时**会重新生成** `src/main` 与 `src/debug` 两份 AndroidManifest ✗
##               —— 手写进去的 `<intent-filter>` 下一次导出就没了 ✓
##               （能长期存活的只有**自定义叠加源**，比如 `src/standard/`＝flavor 源集 ✓）
##            b. 就算放在能存活的地方，也**不能往 `.GodotAppLauncher` 里塞** ✗：
##               Godot 生成的那份 debug 清单给它标了 `tools:node="mergeOnlyAttributes"`
##               （只合并属性、**子元素一律丢掉** ✗）→ 合并报告里明写 REJECTED ✓；
##               叠加源优先级低于 buildType ✗，自己写 merge 也压不过它 ✓
##            c. 破法：在 `src/standard/AndroidManifest.xml` 里声明一个**新名字**的
##               activity-alias（`.PetShareTarget` ✓）——合并器遇到"没见过的组件"就是 ADD ✓，
##               不存在上面那层冲突 ✓（它 targetActivity 指向 .GodotApp 就够 ✓）
##       ⑦ 真机验收：`am start -a SEND` 从**相册的 content://** 发会被系统拦
##          （adb shell 没权限把那条 URI 授给她 ✗ —— 从相册手点分享没这问题 ✓）；
##          自动化测试改用**她自己私有目录里的 file://** ✓，一次跑通：
##          Java 收到 11265 字节 ✓ → 轮询解码 ✓ → 她说"黑白的，一块亮得发白的方块
##          嵌在几块灰格子中间…" ✓✓（收的正是那张天花板照，逐点都对 ✓）
##       ⑧ 一个如实的设计取舍：手机上她看到的是**黑白**的 ✓ —— 这个 feed 给不出可用的色度，
##          硬凑颜色就是之前那张"假红图" ✗；所以掰成灰度 ✓ + 提示词里明说"别硬报颜色" ✓
##       ⑨ **应用内"从相册选一张给她"**（2026-10-09 追加 ✓）：
##          Godot 没有"拉起系统相册"的 API ✗ → 用 **JavaClassWrapper** 调我们自己写的
##          `PetBridge.java`（放构建模板里 ✓，走静态方法 ✓）→ 选中后仍写 files/share_in.jpg ✓
##          → **轮询那条链一个字没改** ✓（它和"系统分享进来"共用同一个后半段 ✓）
##          ⚠️ JavaClassWrapper 三条规矩：只在安卓有 ✓（别的平台 wrap 出空类 ✗）/
##             调完**必须查 `get_exception()`** ✓ / 类名方法名要和 Java **逐字一致** ✓
##       ⑩ 过程教训（我自己栽的 ✗）：改完脚本**先 `--check-only` 再打包** ✓ ——
##          这次给提示词用了**直双引号**（`别当"描述画面"的…` ✗），把 GDScript 字符串提前截断 ✓，
##          真机上 pet_peek 直接解析失败（手机一度是坏的 ✓）。写成「」就没事 ✓
##   6. **一键导出日志**（手机端，2026-10-09）              ✅（真机验过）
##       和桌面**同一条路**（共用 pet_log.export_logs ✓，导出前 _redact 抹掉密钥 ✓），
##       区别只在落点：手机上 `OS.get_system_dir(DESKTOP)` 返回 `/storage/emulated/0` ✗
##       —— 路径**存在**、却是公共存储、应用**写不进去** ✗；老写法只判"在不在"，
##          于是判定通过、建目录失败、直接报"导出失败" ✓
##       → 改成"挨个候选落点**真去建目录**，建得出来才用" ✓ 自然退回 `user://` ✓
##       → 再由 `PetBridge.saveToDownloads` 经 MediaStore 挪进**公共「下载」**✓
##          （沙箱里的文件用户拿不到 ✗，而「下载」是他随手就能转发的地方 ✓）
##       真机验（拆包看了）：10448 字节 ✓ 三个文件齐 ✓
##         **无 sk- 明文、无 Bearer 串** ✓✓（两道隐私：只写"有没有配"+ _redact ✓）
##       入口：设置页「导出日志」按钮 ✓（桌面在右键菜单里 ✓）
##   7. **设置页补齐**（她自己开口 / 她怎么看，2026-10-09）    ✅（真机验过）
##       这四项以前在宿主里是**写死的** ✗（`_proactive_on` / `_proactive.rate` /
##       `camera_every_min` / `camera_position` ✓），而桌面上全都能调 ✓
##       新增四行：主动说话开关 ✓ / 多久没人理她开口（很少·普通·频繁·很频繁 ✓，
##       名字表和桌面 `TALK_RATE_NAMES` 逐字一致 ✓）/ 她多久看一眼（1~60 分钟 ✓）/
##       用哪个摄像头（前置优先·只要前置·用后置 ✓）
##       ⚠️ 顺手修掉一个**真 bug** ✗：`_apply_vision()` 以前只在启动时调一次 ✓ ——
##          在设置页把「看图模型」填上再点保存，摄像头那条**根本不会起来** ✗，
##          非要重启 App 才生效（而设置页还回了句"存好了 ✓" ✗）。
##          现在保存完立刻重算 ✓（填上就建、清空就关 ✓）
##       ⚠️ 那一页也**加上了滚动**：又添四行之后它会超出屏幕下沿 ✓，
##          底下那排「取消 / 保存」原本点不着了 ✗
##       ⚠️ 用户随后提了一条："功能堆在一起不好滑着找" ✓ → 分成四块
##          （AI 后端 / 摄像头 / 她自己 / 工具 ✓，标题带分隔线当路标 ✓），
##          并把「取消 / 保存」**钉在屏幕底部** ✓ —— 十来行的页面不该为了保存滑到底 ✓
##       ⚠️ 换档 / 开关之后**必须重数倒计时** ✓ —— pet_proactive 的硬规矩：
##          不重数的话，停用或旧档期间攒下的时间会在打开的一瞬间就触发 ✓
##   8. **她记得你走开过**（2026-10-09）                ✅（真机验过）
##      真机：退后台 215 秒 → 回来那一刻 [生命周期] 你走开了 **3.6 分钟** →
##      她接上："诶你回来啦，刚溜达了一圈都找不到人。" ✓✓
##       起因是**实测**出来的 ✓：手机上退到后台，主循环被系统暂停 ✓ ——
##       那 150 秒里「每 1 分钟看一眼」一次都没触发 ✗，本地台词也没有 ✗。
##       对她而言那段时间是**空白** ✗：心情按墙钟在衰减 ✓、记忆里却什么都没有 ✓，
##       回来时时间凭空跳一大段 ✓。
##       ⚠️ 这条**不是"保活"** ✗ —— 要她后台真活着，得上前台服务 + 常驻通知，
##          还会更费电 ✓（实测引擎里**没有**现成的前台服务支持 ✗：
##          godot-lib 的清单里 service / notification 一个都没有 ✓）→ 那是另一条路 ✓
##       这里只做一件便宜的：回到前台时她"发现"你走开过、走了多久 ✓
##         · PAUSED 记**墙钟秒**（不用 get_ticks_msec ✗ —— 那是 CLOCK_MONOTONIC，
##           熄屏挂起那段它不走，锁屏两小时会量成"才几分钟" ✓）
##         · RESUMED 相减；<3 分钟不提 ✓；时间跳得离谱（负数/超一天）就跳过 ✓
##         · 忙着 / 气泡还在 / 面板开着 / 生闷气 → 一声不吭 ✓
##         · 连不上后端 → 一句**本地台词** ✓（不让"欢迎回来"反过来依赖联网 ✗）
##   9b. **闹钟式台词通知**（2026-10-09）         ⚠️ **机制通了，投递受系统限制**（半成品 ✓）
##       设计 ✓：她不需要在后台"活着"也能喊你一声 —— 退后台那一刻（引擎还活着 ✓）
##       写下几句台词 ✓ → 排两个 Job（15 / 45 分钟 ✓）→ 到点取一句发成通知 ✓。
##       不需要主循环 ✓、不需要前台服务 ✓、不需要任何额外权限 ✓。
##       真机验到的（每一步都有日志 ✓）：
##         ✅ GDScript：`留了 3 句` ✓ + 台词文件三行齐 ✓ + `闹钟已排` ✓
##         ✅ Java：Job 排进了系统 ✓（`dumpsys jobscheduler` 里看得见 `PetNudgeJobService` ✓）
##         ❌ **投递**：等满 130 秒 + 又等了几分钟，Job 一直没跑 ✗ ——
##            系统给的答复是 `Required: TIMING_DELAY`（没满足 ✓）+ `Reason=frozen`（安卓 11+ 的
##            app freezer ✓）：**缓存中的应用被冻住后，它的闹钟和 Job 都会被押着** ✗✗
##            （先试的 AlarmManager ✓，被 `Reason=frozen` 挡住 ✗ → 才换的 JobScheduler ✓，
##              照样被 `TIMING_DELAY` 挡住 ✗ —— 两条路都实测过 ✓，不是猜的 ✓）
##         💡 已知的解法（没验成 ✗，值得下一步做）：把 App 加进**「电池不受限制」白名单** ✓
##            （`adb shell dumpsys deviceidle whitelist +com.petseek.ard` ✓ 加进去了 ✓，
##              但那一次启动没跑起来 ✓，没测到结果 ✗）→ 值得在设置页加一个按钮直接跳那个开关 ✓
##       ⚠️ 后台那几声是**照本子念**的 ✗（引擎在后台是停的 ✓，她没法思考 ✓）——
##          所以台词只写三句、都只说"你走开了"这件事本身 ✓，不编场景 ✗
##       ⚠️ 生着闷气、或她把「主动说话」关了 → **一句都不留** ✓（她那时候不想搭理你 ✓）
##       ⚠️ 回前台立刻：撤掉没到点的 Job ✓ + 清掉没喊完的台词 ✓
##   9. **后台保活（前台服务那条）**（2026-10-09）      ⛔ **实测不成立，已关掉**
##       做了：Java 前台服务（`PetService.java` ✓，mediaPlayback 类型 + 低重要度通知渠道 ✓）
##             + 清单里三条权限与服务声明（`src/standard/AndroidManifest.xml` ✓）
##             + 退后台拉起、回前台收掉（`_start_keepalive / _stop_keepalive` ✓）
##       真机跑出来的（240 秒 ✓，不可辩驳）：
##         · Java 侧成功 ✓ —— `保活: 前台服务已启动（mediaPlayback）` ✓、通知渠道建出来 ✓、
##           进程自始至终活着（pid 没变 ✓）
##         · Godot 侧失败 ✗ —— 心跳**一次都没打** ✗、相机日志没有 ✗、她一句话也没有 ✗
##       → **前台服务按住的是进程，救不活引擎的主循环** ✗（那路静音音频当时确实"在播 ✓"，
##         也没用 ✓）。所以 `KEEPALIVE_ENABLED = false` ✓ ——
##         一条白挂的常驻通知没有任何好处 ✓，代码留着等换路 ✓
##       两条还能走的路（详见 `_start_keepalive` 上面那段）：
##         · **画中画（PiP）**：她缩成小窗浮在别的 App 上 ✓ —— Activity 保持 resumed、
##           主循环照跑 ✓（唯一能让"她真的还活着"的路 ✓，代价是屏幕上多个小窗 ✓）
##         · **闹钟式台词通知**：零常驻 ✓，到点系统拉起一下、从台词池挑一句发通知 ✓
##           （她不能思考 ✓，但"她偶尔喊你一下"这件事是成立的 ✓）
##  10. **悬浮球 + 气泡 + 小聊天面板**（2026-10-09/10）
##      她浮在别的 App 上 ✓（**原生 View**，见 PetOverlay.java ✓ —— 引擎在后台是停的 ✗，
##      见上面第 9 条，所以这一层只能 Java 画 ✓）；主动说话冒气泡 ✓；点一下弹面板 ✓。
##      ⚠️ 2026-10-10 用户报的 bug ✗：**"弹窗打开后对话关不上"** ——
##        面板上原本只有「说 / 打开她」两句 ✓，要收起只能"再点一下球" ✓；
##        可球一旦不在了（从最近任务直接回她跟前时它已被收掉 ✓／被你拖到屏幕外 ✓），
##        面板就**留在屏幕上、没有门可关** ✗。现在三处一起改：
##          ① 面板上多一个明摆着的「收起」✓；
##          ② 收球时**连面板一起收** ✓（回她跟前屏幕上就只剩她自己 ✓）；
##          ③ 面板位置也**夹进屏幕** ✓（原来只在球下面摆 ✗，球拖到屏幕下沿时
##             面板整个跑到屏幕外 —— "弹出来了但看不见" ✓）
##      ⚠️ 这条**手上还没验过** ✗（2026-10-10）：这台 ROM 把 **adb 注入的触摸**
##         拦在悬浮窗外面 ✓（实测：拖它位置纹丝不动 ✓、点它一条日志都没有 ✓），
##         而你手指点是好的 ✓（你自己就点开过那个面板 ✓）→ 所以这三处改完
##         只能等**手点**一次确认 ✓（球没了面板该跟着没 ✓）
##  11. **双击她 = 截一张屏给她看**（2026-10-10 用户要的）
##      手机上一直缺"偷看屏幕"那一角 ✓（`DisplayServer.screen_get_image()` 移动端没实现 ✗），
##      只能靠主人从相册挑一张 ✓（阶段 5c）。双击她补上"主人不用挑"的另一半 ✓：
##        · 走 **MediaProjection** ✓（安卓只开了这一个口子 ✓，而且**必须主人当面点允许** ✓
##          —— 截屏这件事每次都要主人点头，这才对 ✓）
##        · ⚠️ 安卓 14+ 两条硬规矩（targetSdk 36 ✓ 躲不掉）：清单里要有
##          `FOREGROUND_SERVICE_MEDIA_PROJECTION` ✓、且**取 MediaProjection 之前**
##          必须有 `mediaProjection` 类型的前台服务在跑 ✓ → 于是有个只活一秒的
##          `PetShotService`（先 startForeground 再取 ✓，顺序反了直接 SecurityException ✗）；
##          截完立刻 release ✓（不放掉的话状态栏会一直挂着投屏图标 ✗）
##        · 截下来的 JPEG 写进 **`share_in.jpg`** ✓ —— 和阶段 5c **同一个文件** ✓，
##          于是"轮询 → 解码 → 缩到 1280 → 交给她"那条链**一个字都没改** ✓
##        · 回话走 `shot_status.txt` 一行 ✓（被拒绝 / 没等到帧 / 失败 ✓，她会说一句 ✓
##          —— 被拒绝了不该悄悄没反应 ✗）
##        · 入口两处 ✓：**她 App 里双击她** ✓、**悬浮球上双击** ✓（同一个 Java 口子 ✓）
##      真机验（2026-10-10，App 里双击那条 ✓ 整条走通 ✓）：
##        [截屏] 双击她 → 请系统给一次截屏授权 ✓ → 系统框弹出（MediaProjectionPermissionActivity ✓）
##        → 点头后：`服务已就位（1260×2800 ｜ 560dpi）` ✓ →
##          `已截好 112018 字节 → share_in.jpg` ✓ → `收工（投影已放掉 ✓ 服务已停 ✓）` ✓
##        → 那条现成的链接过去 ✓ → 她看着图说：
##          「诶？这不就是我自己嘛！蓝头发那个，还顶着个箱子…你哪翻出来的呀。」✓✓
##        （截的就是她自己的 App ✓，所以这个回答同时证明"她真看到了那一屏" ✓）
##        ⚠️ 拒一次也验过 ✓：`用户没点头 ✗` → 回话文件写 `denied` ✓ → 她说
##          「你没让我看诶…」✓（被拒绝了不该悄悄没反应 ✓）
##        ⚠️ 悬浮球上双击那条**没验成** ✗ —— 不是代码的事：这台 ROM 把
##          **adb 注入的触摸**挡在悬浮窗外面 ✓（你手指点是好的 ✓），
##          而且后台起前台服务还多一层系统限制 ✓（拦下来会写 `failed` ✓ 她会说一句 ✓）
##      ⚠️⚠️ 用户 2026-10-10 报的真 bug ✗：**"双击后他自动弹回到程序里 →
##         每次截图都是截他自己"** ✓。根子在 `startActivityForResult` ✗：
##         它会把它**发起方所在的那个任务整个提到前台** ✓ —— 我们的 Activity
##         在后台时一样成立 ✓，于是双击球顺手把她自己拉回了屏幕上 ✗，
##         授权完之后截到的自然是她自己 ✓（她回的"底下那句「下次点开始我就看到了」
##         是在跟我说话？"就是**截到她自己界面**的证据 ✓）。
##        修在两处 ✓：
##          ① 拿到授权**立刻 `moveTaskToBack`** ✓（`PetShot.handleActivityResult` ✓）——
##             只在**球浮着**时做 ✓：球浮着 = 你在别的 App 里 ✓；
##             在 App 里双击她是"看我这儿" ✓，那就别把她自己挪走 ✗
##          ② 截屏服务**不再"第一帧就抓"** ✗ → 等 0.7 秒让画面落定、
##             再取**最新**那一帧 ✓（`PetShotService.SETTLE_MS` ✓）
##        ⚠️ 副作用如实记 ✓：App 一退后台，引擎的 `_process` 就是停的 ✗ →
##          这一张会等**你回到她跟前**才被那条链送出去 ✓（内容是对的 ✓，
##          只是"她当场回话"得等回去 ✓ —— 想在球上当场回话，得让 Java 直接喊模型，
##          那是另一条路 ✓）
##  12. **球学会眨眼、会微微晃**（2026-10-10 用户要的）
##      球是 Java 画的 ✓、引擎一退后台就停 ✗ → 所以帧**在启动时先截好** ✓，Java 轮着播 ✓：
##        · 待机那圈：把身体动画**冻住** ✓、`seek()` 逐格定帧 ✓
##          （第一版是"等真实时间"抓 ✗ —— 眨眼那几格落在别的晃动相位上 ✓，
##            球一眨眼她的头会往上跳 8% ✓，两张图一比就看出来了 ✓）
##        · 眨眼：`rig._blink()` 是**现成的口子** ✓（桌面随机眨眼走的就是它）——
##          命令她眨一下、逐格拨 8 格 ✓，再**量**眼睛那一带的差值挑出"半闭 / 闭" ✓
##          （真机量出来：0.000 / 0.062 / 0.043 / 0.000… ✓ —— 身体冻住后其余全是 0 ✓，
##            冒尖那两格就是真闭眼 ✓）
##        · 待机一圈有 **24 秒** ✓，只截了前 2.4 秒 ✓ → Java 那边**往返播** ✓
##          （0→5→0 ✓ 接缝处不用换姿势 ✓；首尾直接循环的话每 2.4 秒会跳一下 ✗）
##        · 顺手加了手感 ✓：**按下去 / 拖动时缩到 0.9** ✓、松手弹回 ✓、
##          **双击先缩一下**再弹回 ✓（动画反馈 ✓）
##        · 存下来的帧：`pet_face_0..5.png` ✓ + `pet_face_b0/b1.png`（半闭/闭 ✓）
##          + `pet_face_frames.txt`（张数 + 每帧毫秒 ✓）；`pet_face.png` 留着当中途兜底 ✓
##      真机验：睁 / 闭 两张的**头顶行差 0 px** ✓（对得齐 ✓），闭眼那张眼睛真闭上了 ✓✓
##      ⚠️ "球在手机上确实在动"这条**要你自己看一眼** ✗ —— 隔着 adb 量不准 ✓：
##        量到两次都被搅了（一次那块正好在放别的画面 ✓、一次球已经被你拖走了 ✓）
##  13. **免授权截屏（无障碍）+ 悬浮窗那几处手感**（2026-10-10 用户要的）
##      用户报的三件事：① 面板开着时双击**截不到** ✗；② 截图**每次都要点系统授权框**、嫌烦 ✓；
##      ③ "整体优化一下" ✓。逐条对应：
##        · **① 双击截不到** ✗→✓ —— 根子在"单击=开合面板"和"双击=截图"抢同一个手势 ✓：
##          面板开着时，第一下落在 420ms 窗口外就被当成又一次单击（只是把面板关了又开 ✓）✗。
##          修两处：面板上补一颗明摆着的「**截图**」按钮（更稳的入口 ✓✓）；
##          `DOUBLE_TAP_MS` 350 → **420** ✓（Java 那侧 + 这里同步改 ✓）
##        · **② 每次都要授权** ✗→✓ —— 换到 **无障碍服务**：`PetShotA11y`
##          （`AccessibilityService.takeScreenshot()` ✓，**开一次免授权** ✓✓）。
##          新增：`PetShotA11y.java` ✓ + `src/standard/res/xml/pet_accessibility.xml`
##          （`canTakeScreenshots="true"` ✓）+ `res/values/strings.xml` ✓ +
##          清单里那个 `<service>`（`BIND_ACCESSIBILITY_SERVICE` ✓ + intent-filter + meta-data ✓）
##          ⚠️ res 也放 **flavor 源集** `src/standard/` ✗（Godot 会重写 main/debug ✓，见文件头铁律 ✓）
##          ⚠️ 门槛两条：安卓 **11（API 30）** 才有这个 API ✓、且要用户自己去系统「无障碍」打开 ✓
##            （我们只能拉起那个页面 ✓ → 设置页加了「截屏」分区：状态 + 去开 ✓）
##          ⚠️ 没开 / 系统太老 → **自动回退**阶段 11 的 MediaProjection ✓
##            （分支在 `PetShot.request` ✓，两条落点/回话**逐字一样** ✓，上层一个字没改 ✓）
##          ⚠️ 无障碍截屏不经过 Activity ✓ → **不需要** mediaProjection 前台服务、
##            也不会像 `startActivityForResult` 那样把她自己拉到前台 ✓✓
##            （阶段 11 那个"截到他自己"的坑，这条路天然没有 ✓）
##        · **③ 手感打磨** ✓：
##          — 面板底部三个按钮**平分一行**（截图 / 打开她 / 收起 ✓）；
##          — 球可拖动时**夹在屏幕里**、松手**吸附到最近的左右边** ✓（带 170ms 动画 ✓）；
##          — 气泡原来**固定贴球右边**✗ → 右边放不下就挪到球左边 ✓、再整体夹进屏幕 ✓
##      真机验：**没验成 ✗**（这台 ROM 把 adb 注入的触摸挡在悬浮窗外 ✓）→
##        等手点确认：① 面板「截图」按钮能截到 ✓；② 开了无障碍后双击**不弹框** ✓；
##        ③ 球松手会吸边 ✓、气泡不再被屏幕裁 ✓
##      ⚠️ 已知会一起被拍进去的：**球/面板自己** ✗（截的是整个屏幕，悬浮窗也在上面 ✓）——
##        面板那条已经"点截图先收面板"兜了一半 ✓，球就先留着（她看见自己的球也说得过去 ✓）

const PetChat := preload("res://scripts/ai/pet_chat.gd")
const PetMood := preload("res://scripts/body/pet_mood.gd")
const PetRig := preload("res://scripts/body/rig/pet_rig.gd")
## 触摸那条链（阶段 1 第 2 步尾，2026-10-08）：判定在 pet_mood.gd，说 + 播动作在 pet_touch.gd，
## 开口 / 哄她选择框在 pet_mood_ui.gd —— 桌面那三份**一字不改**，手机这头把宿主面补齐就行
const PetTouch := preload("res://scripts/body/pet_touch.gd")
const PetMoodUI := preload("res://scripts/body/pet_mood_ui.gd")
const PetShortterm := preload("res://scripts/ai/memory/pet_shortterm.gd")
const PetPointer := preload("res://scripts/body/pet_pointer.gd")
## 对话那条链（阶段 4，2026-10-08）：聊天客户端、接线、记忆
const PetChatFlow := preload("res://scripts/ai/pet_chat_flow.gd")
## 她自己开口那条链（2026-10-09 接上手机）：计时 / 四档频率 / 门禁 / 真开口**全在模块里** ✓
## （模块头部那张"它只碰宿主这些成员"的清单就是本文件要补的东西 ✓）
const PetProactive := preload("res://scripts/ai/pet_proactive.gd")
## 聊天记录（2026-10-08）：存储 + 记录页。
## ⚠️ 桌面那份**没有可复用的存储件** —— 它的对话记录只是宿主内存里一个 60 行数组、
## 重启就没（`desktop_pet._chat_log`），配套的 pet_chat_panel 是按 330×470 + 鼠标写的。
## 所以这两个是手机端**新写**的：存储按 pet_mobile_settings 的套路，UI 按设置页的骨架 ✓
const PetMobileChatlog := preload("res://scripts/mobile/pet_mobile_chatlog.gd")
const PetMobileChatlogUI := preload("res://scripts/mobile/pet_mobile_chatlog_ui.gd")
## 记忆浏览页（2026-10-11，第二梯队⑥"她记得"可见化）：骨架同聊天记录页 ✓
const PetMobileMemviewUI := preload("res://scripts/mobile/pet_mobile_memview_ui.gd")
## 系统分享收图（阶段 5c，2026-10-09）：手机上补上"让主人给她看点东西"这条 ✓
## 三段链路（安卓落盘 → 这里轮询解码 → 走摄像头同一条发送链）见该文件头部 ✓
const PetMobileShare := preload("res://scripts/mobile/pet_mobile_share.gd")
## 快速回答候选条（她说完话递 3 句"你可能接着说"）
const PetQuick := preload("res://scripts/ai/pet_quick.gd")
const PetMemoryHost := preload("res://scripts/ai/memory/pet_memory_host.gd")
const PetMemoryFlow := preload("res://scripts/ai/memory/pet_memory_flow.gd")

## 本地台词（没配 / 连不上 AI 时她说的）。和桌面同一份 —— 一断网就换个人最出戏
const LINES_IDLE: Array[String] = [
	"诶，你在忙什么呀？", "有点无聊…陪我会儿嘛。", "我刚刚是不是又发呆了。",
	"要不要歇一下？", "你一直没理我诶。",
]
## "她自己先开口"那条的尾巴：顺带让模型把"主人可能接着说的 3 句"也写出来。
## **和 desktop_pet.PROMPT_OPTIONS_TAIL 一字不差** —— 格式约定归 pet_chat.gd 管
const PROMPT_OPTIONS_TAIL := "\n\n（说完之后另起一行，行首写两个百分号 %% ，接着写" \
	+ "主人最可能接着说的 3 句话：JSON 数组形式，每条不超过 14 个字，口气随意、像随手打字，" \
	+ "彼此别雷同，也别都写成提问。严格照这个格式，别写别的：\n%% [\"句一\",\"句二\",\"句三\"]）"
## 日志（自己落盘，之后接一键导出）：和桌面**同一份** pet_log.gd。
## 手机上更得靠它 —— 没有控制台，出问题时只能靠 adb 把文件拉出来看：
##   adb shell run-as com.petseek.ard cat files/logs/pet.log
const PetLog := preload("res://scripts/sys/pet_log.gd")
## 手机端界面层（galgame 版式的底部对话框 + 手指按得着的按钮），见同目录 pet_mobile_ui.gd
const PetMobileUI := preload("res://scripts/mobile/pet_mobile_ui.gd")
## 手机端设置（存哪儿、怎么读回来），见同目录 pet_mobile_settings.gd
const PetMobileSettings := preload("res://scripts/mobile/pet_mobile_settings.gd")
## 设置页（右上角⚙打开），见同目录 pet_mobile_settings_ui.gd
const PetMobileSettingsUI := preload("res://scripts/mobile/pet_mobile_settings_ui.gd")
## 时段问候（早安/午饭/晚饭/深夜催睡，2026-10-11），见同目录 pet_mobile_greet.gd
const PetMobileGreet := preload("res://scripts/mobile/pet_mobile_greet.gd")
## 纪念日（她遇见你的那天 / 认识满 N 天，2026-10-11），见同目录 pet_mobile_anniv.gd
const PetMobileAnniv := preload("res://scripts/mobile/pet_mobile_anniv.gd")
## 电量/充电关心（2026-10-11），见同目录 pet_mobile_battery.gd
const PetMobileBattery := preload("res://scripts/mobile/pet_mobile_battery.gd")
## 提醒事项（2026-10-11，第二梯队⑧"到点喊你"）：她的小本本 + 翻给人看的那页 ✓
const PetMobileRemind := preload("res://scripts/mobile/pet_mobile_remind.gd")
const PetMobileRemindUI := preload("res://scripts/mobile/pet_mobile_remind_ui.gd")

## 窥屏 / 摄像头（阶段 5b）：真身就是桌面那份 **pet_peek.gd** —— 它跟 PC 是同一个文件 ✓，
## 摄像头那截（camera_look / camera_shot）本来就跟平台无关 ✓，一个字都不用改 ✓。
## 手机只压掉它里面**唯一一条 Windows 专属的路** ——
## `foreground_text()`：用 PowerShell + user32.dll 去问"前台窗口标题"，
## 手机上没这两样，也不该去读别人开着什么 ✓。
## 它只被 pet_mood_ui.on_reconcile_check 问一句"主人在忙什么" → 一律答"不知道" ✓
const PetPeek := preload("res://scripts/body/pet_peek.gd")

class MobilePeek extends PetPeek:
	func foreground_text() -> String:
		return ""

## 气泡模块的替身：桌面那套（pet_bubble.gd）管多行排版 / 淡出 / 置位，
## 手机上"气泡"就是屏幕底部那条对话框 —— 所以只要"追加一段字"和"在不在"两个动作。
## ⚠️ 名字是 pet_chat_flow 的契约（`_host.bubble.append_token` / `.is_visible()`）
class MobileBubble:
	var _host = null
	func setup(host) -> void:
		_host = host
	## 流式：一段段追加（pet_chat_flow 走这条）
	func append_token(t: String) -> void:
		_set_text(_host._bubble.text + t)
	## 流式开始：清掉上一轮
	func begin_stream() -> void:
		_set_text("")
	## 说一句完整的（pet_quick 点完按钮会用）
	func say(t: String) -> void:
		_set_text(t)
	## "这句得挂一会儿" —— 桌面版是"别淡出"，手机版没有淡出，等于同一件事：
	## 摆上去、留着（pet_quick 换 AI 那组候选时会调它）
	func hold_with(t: String) -> void:
		_set_text(t)
	## 桌面上是"暂停淡出倒计时"，手机上没有倒计时 → 空操作
	func hold() -> void:
		pass
	## 桌面上按文字量算气泡高度；手机上气泡是固定的一块对话框 → 空操作
	func fit(_t: String) -> void:
		pass
	func is_visible() -> bool:
		return _host._bubble != null and _host._bubble.visible
	## ⚠️ 写一次就把它显示出来 —— 四个"说"的入口都走这里，
	## 免得漏掉某个方法忘了设 visible（这类漏法在真机上就是"她说话了但看不见"）
	func _set_text(t: String) -> void:
		if _host._bubble == null:
			return
		_host._bubble.text = t
		_host._bubble.visible = true
		_host._ui.show_line(t)



# ------------------------------------------------------------------ 常量
# **必须和 desktop_pet.gd 同名同值**：pet_memory_host 会读 host._state 去拼"她刚在做什么"，
# 名字对不上不会报错，只会让她一直说错话（最难查的那种）
enum State { IDLE, WALK, DRAG, SLEEP }

## 分隔符的真源在 pet_chat.gd（回复格式归客户端管），这里只是别名 —— 和桌面同一个写法
const OPTIONS_MARK := PetChat.OPTIONS_MARK

## 联系不上外面时她说的那一句（和桌面同一份文案；手机没网的情况比 PC 多得多）
const LINES_OFFLINE: Array[String] = [
	"诶…我好像联系不上外面了。先这样陪你吧。",
	"网是不是断了？那我先不吵你，就待在这儿。",
]
## 电量关心（2026-10-11）的提示词与本地台词。**只给事实**（剩多少电、在不在充 ✓），
## 口气归她 ✓（和 PROMPT_TOUCH / PROMPT_BACK 一个路子 ✓）
const PROMPT_BATTERY_LOW := "（主人手机电量只剩 %d%% 了，还没在充电。" \
	+ "用你自己的口气提醒他充电，一两句就好，可以带点小念叨）"
const PROMPT_BATTERY_CHARGING := "（主人刚把手机插上充电。" \
	+ "用你自己的口气说一句，一两句就好，可以趁机撒个娇）"
const LINES_BATTERY_LOW: Array[String] = [
	"你手机快没电了，早点插上电哦。",
	"电量 %d%% 了……先充电，再陪我。",
	"快没电啦。放下我一会儿，去插上电。",
]
const LINES_BATTERY_CHARGING: Array[String] = [
	"在充电呀。那我陪你待一会儿。",
	"插上电啦？那我不吵你，乖乖等着。",
	"充电好。这样就能多陪我很久了。",
]

## 手机版的设计分辨率（竖屏）。UI 按这个尺寸写，运行时由 content_scale 撑到整屏 ——
## 桌面那份是 330×470（窗口真的那么小），手机上得另给一套
const DESIGN_SIZE := Vector2i(450, 800)

## 摸到不同部位时可能随手播的动作（和桌面那份同一个池子，见 desktop_pet.EMOTE_NAMES）
const EMOTE_NAMES: Array[String] = [
	"extra0", "extra2", "extra3", "extra4", "extra5", "extra6", "extra7",
]

## 摸得太频繁时让她**主动开口**用的提示词。和 desktop_pet.PROMPT_TOUCH 一字不差 ——
## 脚本常量在弱类型引用下取不到（见 CONVENTIONS.md），只能各存一份、setup 时传进去
const PROMPT_TOUCH := "（主人一直在摸你、戳你，没完没了。用你自己的口气跟他说一句，让他停手，" \
	+ "一两句就好。可以有点不耐烦、可以撒着娇地凶他，但别真的长篇大论）"

## 手指挪动超过这个距离就不算"点她"，算划过去（手机上划一下不该被当成摸头）
const TAP_SLOP := 24.0

# ---- 帧率（2026-10-08 真机量出来的：空闲 46% CPU ✗）----
#
# 手机和桌面最大的不同：屏幕是 120Hz 的，而"她站在那儿不动"也要每帧画一遍 ——
# 桌面那台 330×470 的小窗口无所谓，手机上就是实打实的发热和掉电。
# 所以分三档：有互动 60 / 闲着 30 / 退到后台 5。
# 30 帧看不出差别（她的待机是慢呼吸），一有互动立刻回 60，手感不掉。
const FPS_ACTIVE := 60
## 2026-10-08 用户要求"锁帧 60"：原来闲着会压到 30（那一档是**为发热/掉电设的** ——
## 手机屏是 120Hz，她站着不动也要每帧画一遍）。
## 现在不降档了：闲着也 60 ✓
## ⚠️ 代价是真的：如果发现发热/掉电明显，把这里改回 30 就恢复原策略（一行，
## 别动上面的 FPS_ACTIVE ✓）。能不能真跑到 60 取决于下面那条"绘制调用 1708"降下来没有 ✓
const FPS_IDLE := 60
const FPS_BACKGROUND := 5
## 最后一次互动过了这么久，就认为"她闲着"
const IDLE_AFTER := 3.0
## 时段问候（2026-10-11）：开局后等多久才第一次"试着打招呼"（秒）。
## 装配要时间、开局那次探活也还没回来 ✓ —— 太早的话她会以为离线、说本地台词 ✗
## （时段问候和纪念日共用这两个数 ✓ —— 都是"一天一次的那句话" ✓）
const DAILY_FIRST_DELAY := 8.0
## 门禁没过（正忙/面板开着/生闷气）时，多久再试一次（秒）
const DAILY_RETRY_IN := 60.0

# ------------------------------------------------------------------ 宿主接口面 ①（模块直接读这些字段）
var _state: int = State.IDLE
var _chat_streaming := false
var _last_origin: String = ""
var _offline_said := false
var _reply_raw: String = ""
var _stream_shown: String = ""
var _reply_opts_mode := false
var _opts_kind_override: String = ""
var _last_talk_ms: int = 0
## 这次是几点被打开启动的（HH:MM）。写进她的上下文，让她对"这时候被打开"有概念
## （和桌面同一个语义；这类"重启归零的会话状态"归宿主）
var _started_at: String = ""
var _gpu_busy := false          # 手机上没有 GPU 占用率这个概念 → 恒 false（候选照常给）
var _menu_mod = null            # 手机没有那个右键菜单 → 恒 null（模块那边有判空）
var harness = null              # 手机上明确没有本机 dsh（见头部说明）

var _rng := RandomNumberGenerator.new()
var _cjk_font: SystemFont = null
## 气泡模块（手机版替身，见 MobileBubble）
var bubble := MobileBubble.new()
## 候选按钮（真的 pet_quick，2026-10-08 接上）
var _quick := PetQuick.new()
## 对话接线（流式 / 收尾 / 探活）——和桌面**同一份** pet_chat_flow.gd
var _chat_flow := PetChatFlow.new()
## 最近几轮对话（内存，只留 60 行）。**别删** —— `_quick_context()` 拿它给"候选回复"喂上下文 ✓
## （同量级于桌面的 CHAT_LOG_KEEP）
var _chat_history: Array[String] = []
## 落盘的完整聊天记录（上限 500 条）+ 它的显示页。2026-10-08 加
var _chatlog := PetMobileChatlog.new()
var _chatlog_ui := PetMobileChatlogUI.new()
## 记忆浏览页（2026-10-11）：她记得的事 + 可「忘掉」✓
var _memview_ui := PetMobileMemviewUI.new()

# ------------------------------------------------------------------ 她自己开口那条链（2026-10-09）
#
# 逻辑整块在 pet_proactive.gd ✓（倒计时 / 四档频率 / 门禁 / 真正开口 ✓），
# 下面是它**动态访问**的宿主成员 —— 名字必须和 desktop_pet 一致 ✓（改名要两边一起改 ✓）
var _proactive := PetProactive.new()
## 总闸：关掉她就不自己开口。桌面设置面板里能切 ✓；手机设置页暂时没这一项 → 默认开 ✓
##（也就是说手机上她的行为**和桌面默认一致** ✓：会自己找话跟你说 ✓）
var self_talk_enabled: bool = true
## 多久没人理她才自己开口（秒，这段区间里随机 ✓）；四档频率都按它缩放 ✓
var self_talk_after: Vector2 = Vector2(300.0, 900.0)
## 运行时总闸（出厂开 ✓；将来设置页要能切就切它 ✓）
var _proactive_on: bool = true
## 高峰时段少说话：口径**写死在 pet_proactive.peak_active** ✓（DeepSeek 官方峰谷 ✓），
## 这里只留开关本身 ✓
var _peak_reduce_on: bool = false
## "开口前先瞥一眼屏幕"：**手机端恒关** ✓ —— 截屏这条在移动端没有实现 ✓（见头部说明 ✓），
## 而 pet_proactive.ask() 是**无条件**问 `_peek.wants_proactive_peek()` 的 ✓，
## 所以这个值必须是明确的 false ✓（NoPeek 读到就整段跳过 ✓，她照样能自己找话说 ✓）
var _proactive_peek_on: bool = false
## "正在看摄像头"那把锁（门禁之一 ✓）。阶段 5b 接上后由 camera_look 自己拿/放 ✓
var _camera_busy: bool = false
## 「让她看摄像头」的开关（阶段 5b）。**它跟着"看图模型"走** ✓：
## 手机上看图模型只有这一个用途（截屏那条移动端没有 ✗）→ 填了模型就开、留空就关 ✓，
## 免得设置页再多一行。每次保存设置后由 _apply_vision() 重算 ✓
var _camera_on: bool = false
## 她多久自己看一眼（分钟）。桌面默认 10 ✓，手机也 10 —— 再勤就像被盯着了 ✓
var camera_every_min: float = 10.0
## 上一次**真正生效**的间隔（阶段 7）：判断"这次保存有没有改到它" ✓ ——
## 只有这样才重数倒计时（见 _apply_vision ✓），免得存一次密钥就把她下一次看推后十分钟 ✗
var _camera_every_applied: float = 0.0
## 用哪个摄像头（0 = 默认那个）。手机通常还有前置 → 将来设置页要能选就改它 ✓
var camera_index: int = 0
## 用**哪个位置**的摄像头（0 = 前置优先 ✓ / 1 = 只要前置 / 2 = 用后置）。
## 手机上前置对着主人那张脸、后置对着桌子 ✗ —— 她"看一眼"当然该看前置 ✓。
## 挑法在 pet_peek._pick_feed（真机枚举到几个就按位置选 ✓，挑不到再退回 camera_index ✓）
var camera_position: int = 0
## 上一次采集失败的原因（pet_peek 靠它把"没设备"和"有设备但没画面"分开报 ✓）
var _camera_last_error: String = ""
## 看摄像头那条的倒计时（秒）。开局给一整个周期 —— 装上就先拍一张太唐突 ✓
var _camera_timer: float = 0.0
## 下面四个是**截屏那条的字段**，在手机上恒关 ✓：
## 移动端 `DisplayServer.screen_get_image()` 没实现 → 真开只会说"截屏失败了" ✗
## 留着的理由只有一个：pet_peek 那条链会读它们，缺字段就报 "Invalid get index" ✗
var _peek_on: bool = false
var peek_every_min: float = 5.0
var _peek_timer: float = 0.0
var _screen = null

var _chat: PetChat = null
var _vision: PetChat = null
var _mood: PetMood = null
## 触摸 / 情绪 UI（2026-10-08 接上）：判定 → 说一句 → 播动作 → 生气时弹「哄她」选择框
var _touch := PetTouch.new()
var _mood_ui := PetMoodUI.new()
var _memory_host = null
var _memory_flow = null
## 短期记忆（她主动说了、没人接的那些）。手机上目前只被 _soothe / 生闷气结算用到
var _shortterm := PetShortterm.new()
## 窥屏 / 摄像头：阶段 5b 换成真 pet_peek（手机子类，只压掉"问前台窗口"那条 ✓）
var _peek := MobilePeek.new()
## 系统分享收图（阶段 5c）：安卓那侧把分享进来的图落到 user://share_in.jpg ✓，
## 这个模块每秒看一眼 → 有图就解码缩放、走看图链发给她 ✓（见其头部）
var _share := PetMobileShare.new()
## 界面层：底部 galgame 对话框、名字条、"哄她"选择框的位置与字号（见 pet_mobile_ui.gd）
var _ui := PetMobileUI.new()
## 设置（后端地址 / key / 触感开关）。阶段 3 第二部分：先有存取，设置页紧接着做
var _settings := PetMobileSettings.new()
## 摸她的触感反馈开关（pet_mobile_ui.buzz 读它；留成宿主字段是为了设置页能直接改）
var haptic_enabled := true
## 设置页（点右上角⚙打开）
var _settings_ui := PetMobileSettingsUI.new()
## 时段问候（2026-10-11）：早安/午饭/晚饭/深夜催睡，每个时段当天只说一次 ✓
var _greet := PetMobileGreet.new()
## 现在这个时段还有一句招呼没说（_ready 时算一次；说了/时段过了就清掉 ✓）
var _greet_pending := false
## 距离下次"试着打招呼"还有多久（秒）。开局给装配和探活留时间 ✓
var _greet_check_in := 0.0
## 纪念日（2026-10-11）：周年 / 认识满 N 天的那句 ✓（第一次启动记下"相遇日" ✓）
var _anniv := PetMobileAnniv.new()
var _anniv_pending := false
var _anniv_check_in := 0.0
## 电量/充电关心（2026-10-11）：手机桌宠独占的那几句 ✓（逻辑见 pet_mobile_battery.gd ✓）
var _battery := PetMobileBattery.new()
## 提醒事项（2026-10-11，第二梯队⑧）：她的小本本 ✓（解析/存取/到点都在模块里 ✓）+ 管理页 ✓
## ⚠️ 它和问候/电量那些"她自己想起来"的**不是一类** ✓：到点就喊，
## **不看她主动说话那个开关** ✓ —— 你拜托她的事，开关管不着 ✓
var _remind := PetMobileRemind.new()
var _remind_ui := PetMobileRemindUI.new()
## 多久看一次"有没有到点的"（秒）。到点是分钟级的事，10 秒够 ✓
const REMIND_POLL_IN := 10.0
## 退后台时给她排多久内要到点的（秒）。一整天 ✓ —— 更远的等她下次退后台自然重排 ✓
## （后台会话能持续多久本来就说不好 ✓，排个三天后的到点纯属自我安慰 ✗）
const REMIND_BG_WINDOW := 86400.0
## 距离下次看"有没有到点的"还有多久（秒）。开局给装配留时间 ✓
var _remind_check_in := 0.0
var memory = null
var memory_enabled := true
var memory_observe := true
## 让她用模型抽记忆（多一次非流式请求 ✓）。**这三个字段以前漏了** ✗ ——
## 2026-10-09 真机抓到的：看她摄像头那条说完话进记忆收尾时，
##   SCRIPT ERROR: Invalid access to property or key 'memory_ai_extract'
##   at note_observation (pet_memory_flow.gd:143)
## 也就是"她看着图说过的话"根本没进记忆 ✓（settings 面板上那几项手机上也没有 ✓，
## 所以这不是"设置没配"，是宿主字段缺 ✓）。默认值照桌面那份 ✓
var memory_ai_extract := true
var memory_ai_every_sec := 30.0
var memory_summary_every := 6

## ⚠️ 这两个只是"设置模块读不到时的兜底"，正常由 pet_mobile_settings 覆盖（见 _ready）。
## 别再写 127.0.0.1 —— 手机上那个地址指的是手机自己，一定连不上（2026-10-08 真机踩过）
var chat_url := "https://api.deepseek.com"
var chat_model := "deepseek-flash"
var chat_access_key := ""
var vision_model := ""
var vision_access_key := ""
var chat_persona_name := "小蓝"
var chat_system_prompt := ""
var chat_enabled := true
var hibernate_when_offline := false
## 候选条那几项（默认值和桌面一致，见 desktop_pet 的 @export）
var quick_enabled := true
var quick_ai := true
## 她自己先开口时递候选的概率。**不给 1.0 是刻意的**：每次都有就成"必看的表"了
var quick_chance := 0.7
## 聊天之后也概率递一次（比主动开口低 —— 聊天时你正打着字，按钮反而碍事）
var quick_chance_chat := 0.20
## 候选那条单独用哪个模型。留空 = 跟聊天同一个
var quick_model := ""

# ------------------------------------------------------------------ 宿主接口面 ②（pet_rig 那份，值抄自 desktop_pet 的 @export）
## 她在画面里占多高（1.0 = 顶到边）。数字是**量出来的**，不是拍的：
## 0.70 + lift 0.12 时她中心在 y=395（偏上 105 像素 ✗）；改到 lift 0 后中心回到 507 ✓，
## 但那时她占 745 像素高、脚会插进对话框 46 像素 ✗ → 再收到 0.58：
## 中心 507 ✓（居中）+ 底部 827 ✓（整只都在对话框上沿 834 以上）
## 2026-10-08 用户反馈「实机明显小了一圈」（对着 PC 那台 0.78 比）→ 从 0.55 往上调。
## 先试的 0.65 **被探针实测否掉** ✗：脚底 y=876 ｜ 对话框上沿 y=826 → 脚进对话框 50px ✗。
## （教训：不能只用 fit × 画面高估 —— 取景是 18° 俯视，标定盒子的**进深**也被投了进来，
##  0.65 那档她的实际投影高是 752px 而不是 650px ✗。要么实测，要么别拍脑袋。）
## 现在这档 0.60 + lift 0.05：脚底 ≈817 ✓ 仍整只在对话框上方，她比原来大约 9%。
## 上限其实是**横向**卡住的：标定盒子投影宽 488px@0.65 → 450 宽的屏最多到 ~0.60 ✗。
## 想完全贴 PC 的 0.78 只有一条路：改 galgame 版式（对话框变矮 / 半透明 / 只在说话时出现）
## 给底部腾出 ~100px。那是版式的决定，不是这个数字能解决的 ✓
var fit_ratio: float = 0.60
## 取景的纵向偏移（单位是"她的身高"）：正数 = 镜头看向她**下方** → 她在画面里**上移**。
## ⚠️ 方向别搞反（2026-10-08 栽过）：写成 `+=`（往上看）会把她整只推到屏幕下缘、头都裁掉。
## 真机实测（截图直接量的）：0.12 时她中心在 y=395，比画面中心（500）**高 105 像素** ✗；
## 降到 0 中心就回到 ~465 —— 视觉上就是居中了，脚仍比对话框上沿高 36 像素 ✓
## 2026-10-08 配 fit 0.60 取 0.05：只把脚从 ~847 抬到 ~817（30px），不是当初那个扎眼的 105px
var frame_lift: float = 0.05
## 取景的横向偏移（单位同上）：正数 = 她在画面里**往右**移。
## 为什么需要它：取景是照**标定包围盒**的中心对齐的，而那个盒子不对称（把"会往右伸"的
## 动作也并进去了）→ 她实际会偏左。真机截图量出来偏 25 像素，折算成她的身高是 0.043
var frame_shift_x: float = 0.043
var anim_speed: float = 0.7
var texture_filter_mode: int = BaseMaterial3D.TEXTURE_FILTER_NEAREST
var alpha_scissor_threshold: float = 0.5
var dilate_pixels: int = 2
## 顶点吸附到屏幕像素格点（治晃动时缝隙边缘的移动锯齿 ✓，原理见 pet_rig_tex / pixel_snap.gdshader）。
## 值抄自 desktop_pet 的同名 @export —— 两端一致，手机上看到的和桌面一样 ✓
## ⚠️ 2026-10-09 默认 false ✗：逐顶点吸附会让相邻部件各自跳格 → 缝隙一格一格开合 ✗，
## 用户实测"还不如之前" ✗。为什么、以及另一条路见 desktop_pet.gd 同名参数的注释 ✓
var pixel_snap: bool = false
var uv_inset_texels: float = 0.0
## ⚠️ 2026-10-09 从 0.5 改成 0（和 desktop_pet 同名参数一致 ✓）：内缩会把这块面的贴图
## 放大（窄面最多 +25% ✗）→ 图集里的细白缝变粗 → "像素块之间有白色轮廓" ✗。
## 边界现在交给 dilate_image 的"就近取色" ✓（越界采样拿到本块自己的颜色 ✓）。
var disable_specular: bool = true
## 是否把"一次性动作的计时"裁到动作真正结束的那一刻（值抄自 desktop_pet 的 @export）。
## ⚠️ 这个漏了就是**每次播动作都报一次运行时错**（pet_rig_stats.action_time 会读它）——
## 2026-10-08 探针抓到的：手机上点她的头、她刚开口，stderr 里就一行
## "Invalid access to property or key 'action_tail_trim'"。弱类型契约漏字段就是这样：
## 不编译不过，只在真跑起来的那一刻喊一声
var action_tail_trim: bool = true
## 裙摆外扩倍率（1.0 = 关闭）。裙板和她的腿本来是互相插着的，放大会让整圈裙摆离开腿。
## 值抄自 desktop_pet 的同名 @export —— 两端一致，手机上看到的和桌面一样
## ⚠️ 2026-10-08 临时改成 1.0：用户反馈"她像素模块位置有很大出入" ——
## 今天唯一改动方块位置的就是这个参数（把 50 块裙板整圈往外推 + 各自放大 6% ✓）。
## 这一版是"**原始裙摆位置**"，用来直接对比"到底哪个才对" ✓
## 判定完之后：要原始位置就留 1.0；要外扩就改回 1.12（桌面的 @export 默认值也是 1.12 ✓）
var skirt_expand: float = 1.12
## 眨眼：`blink_chance` 是每帧概率、`blink_slowdown` 是倍率（值抄自 desktop_pet 的 @export）。
## ⚠️ 这两个漏了不会"编译不过" —— rig 是弱类型读宿主，报错是**每帧一次**的运行时错
var blink_chance: float = 0.006
var blink_slowdown: float = 2.5

var _scale_pct: float = 1.0
var _has: Dictionary = {}            # 动画名 → true（rig._scan_animations 填）
var _action_end: Dictionary = {}     # 一次性动作"真正做到哪一刻"（rig._measure_action_ends 填）
var _calib_aabb := AABB()
var _calibrated := false
var _aabb_cache := AABB()
var _aabb_frame: int = -1
var _idle_anim: String = ""
var _ground_offset: float = 0.0
var _timer: float = 3.0
## 还要多久算"她闲着"（秒）。>0 保持满帧，减到 0 就降帧
var _active_left: float = IDLE_AFTER

var rig: PetRig = null

@onready var _character: Node3D = $Character
@onready var _pivot: Node3D = $Character/Pivot
@onready var _model: Node3D = $Character/Pivot/Model
@onready var _anim: AnimationPlayer = $Character/Pivot/Model/AnimationPlayer
@onready var _anim_face: AnimationPlayer = null
@onready var _camera: Camera3D = $Camera3D
@onready var _bubble: Label = $UI/Anchor/Bubble

# ------------------------------------------------------------------ 生命周期

func _ready() -> void:
	# 设计分辨率撑到整屏（竖屏）。项目设置里 stretch=canvas_items / aspect=expand，这里只给基准尺寸
	var win := get_window()
	win.content_scale_size = DESIGN_SIZE
	# ⚠️ 工程里 `viewport/transparent_background=true` 是给**桌面**透明用的（她背后要能看见你的
	# 桌面）。手机是个普通 App，根视口必须不透明 —— 否则背景是透的，Android 那边会显示成黑块
	win.transparent_bg = false
	# 模型的正面朝 -Z、相机在 +Z，所以基准旋转 PI 才正对镜头（见 pet_walk.FACING_BASE）。
	# 桌面上这个角度是"走路朝向"那条链推出来的；手机版她站着不动 → 直接摆正
	_model.rotation.y = PI
	# "几点被打开" —— 拼上下文时要用（见 pet_memory_host 的 "started_at"）
	var _st := Time.get_datetime_dict_from_system()
	_started_at = "%02d:%02d" % [int(_st["hour"]), int(_st["minute"])]

	# ⚠️ 主动说话那条**必须在这里就接线**（抄 desktop_pet 的同一条纪律 ✓）：
	# 下面读设置/应用设置时可能会调 `_proactive.reschedule()`（重数倒计时 ✓），
	# 那时 host 还是 null 就白数了（见 pet_proactive.span / rand_delay 的空宿主分支 ✓）
	_proactive.setup(self)

	# ⚠️ **设置必须在最前面读进来**（2026-10-08 真机踩到）：
	# 原先我把它放在 _ready 末尾，而建聊天客户端在它前面 —— 结果是客户端拿到了**空 key**，
	# 真机上表现成"填了 key 也 401"（那个 401 其实是"根本没带密钥"）。
	# 记住这条链：读设置 → 建记忆 → 建客户端 → 拼人设
	_settings.load_settings()
	_settings.apply_to(self)
	_settings_ui.setup(self)
	PetLog.log("设置", _settings.describe())
	_request_notify_permission()      # 阶段 9b：她在后台喊你需要它 ✓（她主动说话时才要 ✓）

	var t0 := Time.get_ticks_msec()
	rig = PetRig.new()
	rig.setup(self)
	# ⚠️ **顺序就是契约**（抄自 desktop_pet._ready 那一段）：校准要读 _idle_anim，
	# 所以 build_idle 必须在 calibrate 之前
	rig._fix_crossed_leg_parts()
	rig._scan_animations()        # 里面会建表情叠加层并连好信号（眨眼就走它）
	rig._apply_anim_speed()
	rig._harden_materials()       # 像素画采样 + 关 alpha 抗锯齿，消轮廓白边
	rig._inset_uvs()              # 面片 UV 内缩半 texel
	rig._build_idle_anim()
	rig._apply_loop_modes()
	rig._calibrate()              # 量包围盒（手机上这一步最贵）
	rig._measure_action_ends()
	_frame_camera()
	var cost := Time.get_ticks_msec() - t0
	print("[PetDeek] 手机端装配完成：%d ms ｜ 动画 %d 个 ｜ 待机 %s ｜ 相机 size=%.3f" % [
		cost, _has.size(), _idle_anim, _camera.size])
	print("[PetDeek] 手机宿主起来了（阶段 1 第 2 步：3D 已装）")

	# 情绪：零外部依赖，先建起来
	_mood = PetMood.new()
	_mood.setup(self)
	# 情绪落盘：App 退到后台/关掉再打开，她还记得上次的心情（和桌面同一个文件格式）。
	# 存档在工程自己的 user:// 里 —— 手机上是应用沙箱，和 PC 那份互不相干（见 project.godot）
	_mood.load()
	# 中文字体：项目里没配 CJK 字体，Godot 默认字体渲染汉字会掉字 ——
	# 桌面上是 pet_chat_panel 补的这件事，手机这头在这里补（气泡，以及以后的选项按钮）
	_build_cjk_font()
	# 界面层：把气泡改成贴底的 galgame 对话框（要中文字体，所以排在 _build_cjk_font 之后）
	_ui.setup(self)
	# 聊天记录（2026-10-08）：先读盘（读回来的最后 60 条也灌进 _chat_history ——
	# 这样重启之后"喂给候选回复的上下文"不是空的 ✓），再建记录页（首次打开才真建控件 ✓）
	_chatlog.load_from_disk()
	_chatlog_ui.setup(self)
	# 记忆浏览页（2026-10-11）：同样首次打开才建控件 ✓（记忆本体在下面
	# _memory_host.setup_memory() 才建 —— 页面 open 时再读也来得及 ✓）
	_memview_ui.setup(self)
	for row in _chatlog.all().slice(maxi(0, _chatlog.size() - 60)):
		if row is Dictionary:
			_chat_history.append("%s：%s" % [String(row.get("who", "")), String(row.get("text", ""))])
	# 触摸那条链：短期记忆 → 被摸到的反应 → 开口 / 哄她选择框
	_shortterm.setup(self)
	_touch.setup(self, PROMPT_TOUCH, EMOTE_NAMES)
	_mood_ui.setup(self)
	# 阶段 5b：窥屏/摄像头的真身（原来的 NoPeek 替身退休 ✓）——
	# pet_mood_ui 会问它"主人在忙什么"，它答"不知道" ✓
	_peek.setup(self)
	# 阶段 9：那路静音音频**在这里就建好** ✓ —— 别等到 PAUSED 那一刻才往树里加节点 ✓
	_build_keepalive_audio()
	# 阶段 10：给她截一张正视图头像（悬浮球用 ✓）—— 延到帧末，别挡住装配 ✓
	_capture_face.call_deferred()
	_share.setup(self)           # 阶段 5c：系统分享进来的图（轮询 → 解码 → 发给她 ✓）
	# 心情变了 → 播一个"能体现这个情绪"的动作（动作表在 pet_mood_ui.MOOD_ACTIONS）
	_mood.mood_changed.connect(_on_mood_changed)
	# ⚠️ **一次性动作播完要回待机** —— 这一条 2026-10-08 漏了，症状是"做完一个动作就卡住"：
	# rig 里 `_on_main_finished` 早写好了（播完回 idle），但那是**宿主负责连的信号**
	# （桌面上在 desktop_pet 里连的），手机宿主没连 → AnimationPlayer 停在最后一帧，
	# 而她不会自己动 → 画面也就"只在有输入时才变"（我一直以为是渲染的问题）
	_anim.animation_finished.connect(_on_main_finished)
	var ap := _anim
	if ap != null and _idle_anim != "":
		ap.play(_idle_anim)

	# ---- 对话那条链（阶段 4）----
	# 顺序照 desktop_pet：**先建记忆再建客户端** —— 拼人设时要拿记忆往里塞
	_memory_host = PetMemoryHost.new()
	_memory_host.setup(self)
	_memory_host.setup_memory()          # 建 memory 并读盘（手机上就在应用沙箱里）
	_memory_flow = PetMemoryFlow.new()
	_memory_flow.setup(self)
	_setup_chat()
	print("[PetDeek] 手机宿主：触摸/摸头已接上（点她 = 摸她；在闹情绪时得点到「哄她」才算数）")

	# ---- 时段问候（2026-10-11）----
	# 现在这个时段该打招呼、今天还没打过 → 排上 ✓。**等一会儿再试** ✓：
	# 装配要时间、开局那次探活也还没回来 ✓（8 秒后第一次尝试，之后看门禁重试 ✓）
	_greet.load()
	if _greet.due(Time.get_datetime_dict_from_system()) != "":
		_greet_pending = true
		_greet_check_in = DAILY_FIRST_DELAY
		PetLog.log("时段问候", "这个时段有句招呼没说 → %d 秒后试一次 ✓" % DAILY_FIRST_DELAY)
	# 纪念日（2026-10-11）：第一次启动会记下"今天"= 她遇见你的那天 ✓；
	# 到周年/认识第 N 天的那天，她会提一句 ✓
	_anniv.ensure(Time.get_datetime_dict_from_system())
	if not _anniv.due(Time.get_datetime_dict_from_system()).is_empty():
		_anniv_pending = true
		_anniv_check_in = DAILY_FIRST_DELAY
		PetLog.log("纪念日", "今天是个该记住的日子 → %d 秒后说一句 ✓" % DAILY_FIRST_DELAY)
	# 提醒事项（2026-10-11）：读她的小本本 ✓，管理页同样首次打开才建控件 ✓。
	# 也等一会儿再看（装配要时间 ✓）；到点那条**不看主动说话开关** ✓（见字段那边 ✓）
	_remind.load()
	_remind_ui.setup(self)
	_remind_check_in = DAILY_FIRST_DELAY
	var open_n := _remind.count_open()
	if open_n > 0:
		PetLog.log("提醒", "小本本上还有 %d 条没说 ✓" % open_n)

	# 帧率：先满帧起（装配后的头几秒总有人在看），然后靠 _process 里的倒计时降档
	Engine.max_fps = FPS_ACTIVE
	_active_left = IDLE_AFTER
	# 日志：从这几行起就有"可导出的现场"了（格式和桌面同一份，见 sys/pet_log.gd）
	PetLog.log("启动", "手机端 ｜ 引擎 %s ｜ 数据目录 %s" % [
		Engine.get_version_info().get("string", "?"), OS.get_user_data_dir()])
	PetLog.log("启动", "装配耗时 %d ms（动画 %d 个，待机 %s，GPU %s）" % [
		cost, _has.size(), _idle_anim, _gpu_name()])
	PetLog.log("启动", "屏幕 %s ｜ 缩放 %.2f ｜ 帧率分档 %d/%d/%d" % [
		DisplayServer.screen_get_size(), DisplayServer.screen_get_scale(),
		FPS_ACTIVE, FPS_IDLE, FPS_BACKGROUND])
	# 她这会儿是不是"残的"，开局就写清楚，省得后面一句一句猜
	if chat_access_key.strip_edges() == "":
		PetLog.warn("设置", "还没填 AI 的 key → 她只会说本地台词（在设置页里填）")
	# 主动开口那条的现场（2026-10-09 接上 ✓）：开着的话她会自己找话说；
	# 间隔按 self_talk_after × 当前档缩放（口径在 pet_proactive.span_for ✓）
	var _sp: Vector2 = _proactive.span()
	PetLog.log("主动开口", "总闸 %s ｜ 间隔 %.0f~%.0f 秒 ｜ 开口前偷看屏幕：%s（手机端没有截屏这条 ✓）" % [
		("开" if _proactive_on else "关"), _sp.x, _sp.y,
		("开" if _proactive_peek_on else "关")])

# ------------------------------------------------------------------ 对话那条链（阶段 4）

## 建聊天客户端 + 接线。和 desktop_pet 同一套做法，只是手机上少一样：
##   dsh（本机 agent）—— `harness` 恒 null，pet_chat_flow 自己会判空跳过 ✓
## 视觉那条（阶段 5b 起）交给 _apply_vision()：配了看图模型才建 ✓
## 安卓 13+ 通知要用户点头才会显示 ✓（没有它，她在后台喊你也看不见 ✗）。
## 什么时候要：**只在她本来就会主动说话时**才要 ✓ —— 不然是白要一个权限 ✗
## （和后端密钥那条同一个原则：功能没开就别伸手 ✓）
func _request_notify_permission() -> void:
	if OS.get_name() != "Android":
		return
	const PERM := "android.permission.POST_NOTIFICATIONS"
	if OS.get_granted_permissions().has(PERM):
		return
	if not self_talk_enabled:
		return
	OS.request_permission(PERM)
	if OS.is_debug_build():
		print("[PetDeek] 申请通知权限（安卓 13+ 那条运行时权限 ✓）")

func _setup_chat() -> void:
	_chat = PetChat.new()
	_chat.configure(chat_url, chat_access_key, chat_model)
	_chat.system_prompt = chat_system_prompt
	# 上下文提供者：每轮把「她是谁 + 记忆 + 现在」拼在历史之后（实现在 pet_memory_host）
	_chat.context_provider = func(query: String) -> String:
		return _memory_host.context_for(query)
	# 一轮对话的四个出口 + 探活，全接到 pet_chat_flow（和桌面同一份接线）
	_chat.token.connect(_chat_flow.on_token)
	_chat.replied.connect(_chat_flow.on_replied)
	_chat.failed.connect(_chat_flow.on_failed)
	_chat.stream_ended.connect(_chat_flow.on_stream_ended)
	_chat.reachable.connect(_chat_flow.on_reachable)
	# 记忆那条后台请求（抽事实 / 更新摘要）走 once_* 两个信号
	_chat.once_done.connect(_memory_flow.task_done)
	_chat.once_failed.connect(_memory_flow.task_failed)
	_chat_flow.setup(self)
	bubble.setup(self)
	# 候选条：挂在同一个 anchor 下。点某句候选 = 主人说了那句话 → 走正常发送链路
	# （所以它也会进记忆 ✓）。位置和字号由界面层接管（照桌面气泡摆的话会掉到屏幕外）
	_quick.setup(self, get_node_or_null("UI/Anchor") as Control, _bubble, bubble, _cjk_font)
	_quick.picked.connect(_submit_chat)
	_quick.configure(chat_url, chat_access_key, _quick_model_name())
	_memory_host.refresh_persona()     # 拼一遍人设（里面会把系统提示词写进 _chat）
	_chat.probe_now()                  # 开局探一次，不等定时器
	_apply_vision()                    # 看图/摄像头那条（阶段 5b）：配了模型才建 ✓
	PetLog.log("聊天", "客户端就绪 ｜ %s ｜ 模型 %s ｜ key %s ｜ 看图 %s" % [
		chat_url, chat_model, "有" if chat_access_key != "" else "没有（只会说本地台词）",
		"开（" + vision_model + "）" if _camera_on else "关"])

## 设置改完之后调它：**把新值重新装进正在跑的那个客户端** ——
## 不重装的话要重启 App 才生效（2026-10-08 真机踩到：填了 key 保存，还是用旧的空 key 在发）
func on_settings_saved() -> void:
	if _chat != null:
		_chat.configure(chat_url, chat_access_key, chat_model)
		_chat.probe_now()
		# 人设也跟着重拼一遍（她的名字 / 后端相关的那几段可能变了）
		_memory_host.refresh_persona()
	if _quick != null:
		_quick.configure(chat_url, chat_access_key, _quick_model_name())
	# ⚠️ 阶段 7 修掉的一个**真 bug**：看图那条以前只在启动时接一次 ✗ ——
	# 用户在设置页把「看图模型」填上、点保存，摄像头那条**根本不会起来** ✗，
	# 非要重启 App 才生效（而设置页还回了句"存好了 ✓" ✗）。现在保存完立刻重算：
	# 填上就建 ✓、清空就关 ✓、间隔/位置新值也顺带生效 ✓
	_apply_vision()
	# 主动说话那几项同理：换档 / 关掉再打开之后**必须重数倒计时** ✓
	#（模块的规矩：不重数的话，停用或旧档期间攒下的时间会在打开的一瞬间就触发 ✓）
	_proactive.reschedule()
	_request_notify_permission()      # 刚把「主动说话」打开的话，这时候才该要通知权限 ✓
	PetLog.log("设置", "已重新装进客户端：%s" % _settings.describe())

## 候选那条用哪个模型：留空就跟聊天同一个（和桌面的 quick_model 一个语义）
func _quick_model_name() -> String:
	return quick_model.strip_edges() if quick_model.strip_edges() != "" else chat_model

## 主人说了一句话（阶段 4 第二片的输入框和候选按钮都走它）。
## **和桌面同一个顺序**：先给情绪过一眼 → 记进对话记录和长期记忆 → 再发出去
func _submit_chat(text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	_mood.say_about_master(t)      # 主人打出来的字比截图更直接（悲伤靠这条自主积攒）
	_push_chat_line("我", t)
	_memory_flow.note_user_message(t)
	# 提醒事项（2026-10-11）：她有个小本本 ✓ —— "提醒我十分钟后开会"这种话当场记下 ✓
	# ⚠️ **不告诉模型** ✓：她照常回她的话（"记住了！"✓），小本本这边安静记账 ✓
	#（硬往这句里塞"你已记下了"只会把她回话的口气带怪 ✗）。认不出就当没这事 ✓
	var r := _remind.parse(t, Time.get_datetime_dict_from_system())
	if not r.is_empty():
		_remind.add(String(r["text"]), float(r["due"]))
	_last_origin = "chat"
	if _chat == null or not _chat.send(t):
		_say_local("唔…我这边好像没连上，等下再跟我说一遍？")
		return
	_bump_fps()

## 显卡名（导出日志里"她跑在什么机器上"那一行）。
## 两个来源：桌面上 `OS.get_video_adapter_driver_info()` 有；**安卓上它返回空**
## （2026-10-08 真机实测，日志里那行只剩个 "GPU "），所以再问一次 RenderingServer。
## 两边都取不到就给空串 —— 日志少一行不算错，别为了它抛异常
func _gpu_name() -> String:
	if OS.has_method("get_video_adapter_driver_info"):
		var drv: PackedStringArray = OS.get_video_adapter_driver_info()
		if drv.size() >= 2:
			return "%s %s" % [drv[0], drv[1]]
	var name := RenderingServer.get_video_adapter_name()
	if name == "":
		return ""
	return "%s（驱动 %s）" % [name, RenderingServer.get_video_adapter_api_version()]

## 中文字体。**不能用桌面那份字体名**：Windows 常有的雅黑/黑体 Android 上没有 ——
## 给它一串候选（安卓的 Noto/思源在最前），SystemFont 挨个找，找不到还有系统兜底
func _build_cjk_font() -> void:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Noto Sans CJK SC", "Source Han Sans CN", "Droid Sans Fallback",
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif",
	])
	_cjk_font = f
	if _bubble != null:
		_bubble.add_theme_font_override("font", _cjk_font)

## 取景：抄 pet_window.frame_character 的那套算法（落地高度 + 正交 size + 18° 俯视）——
## 手机上没有"窗口"，但"她在画面里多大、踩在哪条线上"必须和桌面一致
func _frame_camera() -> void:
	var box := _calib_aabb
	if box.size.y <= 0.01:
		return
	var h := box.size.y
	_ground_offset = -box.position.y
	_pivot.position.y = _ground_offset
	box.position.y = 0.0
	_camera.size = h / clampf(fit_ratio, 0.2, 1.0) / clampf(_scale_pct, 0.1, 5.0)
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	var center: Vector3 = box.position + box.size * 0.5
	# 手机上她脚底下压着一条 galgame 对话框（屏幕底部约 20%），所以取景要让她**往上走**。
	# ⚠️ 方向别搞反（2026-10-08 栽过）：要让被摄体在画面里**上移**，镜头得看向它**下方** ——
	# `center.y += …`（往上看）会把她整只推到屏幕下缘、头都裁掉；得是 `-=`。
	# 0.12 是照这台真机的设计空间（450×1000）算的：她占 700 像素高，画面中心下方
	# 那 83 像素 ≈ 0.12h —— 正好落进"屏幕顶到对话框上沿"那一段的中间。屏幕比例变了调这个数
	center.y -= h * frame_lift
	# 横向同理：要把她往右挪，镜头得看向她**左**边（和纵向一个道理，别写反）
	center.x -= h * frame_shift_x
	var tilt := deg_to_rad(18.0)
	var dist: float = maxf(h * 3.0, 5.0)
	_camera.global_position = center + Vector3(0.0, sin(tilt) * dist, cos(tilt) * dist)
	_camera.look_at(center, Vector3.UP)

func _process(delta: float) -> void:
	if rig != null:
		rig._update_idle_face()       # 眨眼 / 表情叠加层
	_perf_tick(delta)                 # 只在 debug 包：每 5 秒打一行 fps / 脚本耗时 / 绘制调用
	if _mood_ui != null:
		_mood_ui.tick()               # 「哄她」选择框 8 秒没点就自己收掉
	if _ui != null:
		_ui.tick()                    # 对话框/名字条跟着走 + 选择框摆到手机上该在的地方
	# 情绪衰减 / 聊天连接 / 探活 / 生闷气那几条统一由 chat_flow 推。
	# ⚠️ 它内部会调 `_host._mood.tick()`，所以这儿**别再单独调一次**（会把衰减算两遍）
	if _chat_flow != null:
		_chat_flow.tick(delta)
	# 阶段 5c：主人刚分享过来的图 —— **放在"她自己开口"之前** ✓
	#（主人给的东西优先 ✓；而且发出去之后 self_talk 的门禁自然会看到"她正忙"✓，不会两句叠着说 ✗）
	if _share != null:
		_share.tick(delta)
	# 她自己开口那条（2026-10-09 接上 ✓）：倒计时到点就让她找话说 ✓。
	# 六道门禁都在模块里（总闸 / 生闷气 / 离线 / 正忙 / 面板开着 / 气泡还在 ✓），
	# 这里只推时间 ✓ —— 放在 chat_flow 之后，门禁读到的是这一帧最新的状态 ✓
	_check_self_talk(delta)
	# 时段问候（2026-10-11）：到点儿那句招呼 ✓（自己带着倒计时，没排就不走 ✓）
	_greet_tick(delta)
	# 纪念日（2026-10-11）：周年 / 认识满 N 天那句 ✓
	_anniv_tick(delta)
	# 电量/充电关心（2026-10-11）：她会在你没电时念叨你 ✓
	_battery_tick(delta)
	# 提醒事项（2026-10-11）：到点的那条喊出来 ✓（问候/电量看她主动说话的开关，
	# 这条是主人拜托的 → 不看 ✓；门禁还是同一套，正忙着就等下一轮 ✓）
	_remind_tick(delta)
	# 注：pet_memory_flow 是**事件驱动**的（note_user_message / note_exchange / note_observation），
	# 没有 tick —— 别照着桌面的老印象在这儿补一个
	# 闲置降帧：倒计时走完就压到 30（一有互动，_bump_fps 会把它拉回 60）
	if _active_left > 0.0:
		_active_left -= delta
		if _active_left <= 0.0:
			Engine.max_fps = FPS_IDLE

## 有互动 → 回满帧，并重新开始"空闲倒计时"。触摸 / 她开口 / 心情变化三处调它
func _bump_fps() -> void:
	if _active_left <= 0.0:
		Engine.max_fps = FPS_ACTIVE
	_active_left = IDLE_AFTER

# ------------------------------------------------------------------ 她说话（模块按老名字调）
# 桌面那套是"气泡 + 流式 + 任务栏"；手机上先只打印 + 一个静态气泡，第 4 步接流式

func _say(text: String) -> void:
	_bump_fps()                 # 她开口 = 有戏看，帧率别省着
	print("[她] " + text)
	if _bubble != null:
		_bubble.text = text
		_bubble.visible = true
	_ui.show_line(text)         # 顺带把名字条和"点一下继续"摆好
	_widget_note(text)          # 阶段⑤：桌面上那块卡片也跟着换一句 ✓

## 没话可说时的本地台词。⚠️ **必须给默认值** ——
## `pet_chat_flow.on_failed` 是不带参数调它的（`_host._say_local()`）
func _say_local(text: String = "") -> void:
	if text == "":
		text = LINES_IDLE[_rng.randi_range(0, LINES_IDLE.size() - 1)]
	print("[她·本地] " + text)
	if _bubble != null:
		_bubble.text = text
		_bubble.visible = true
	_ui.show_line(text)
	_widget_note(text)          # 阶段⑤：本地兜底那句也上卡片 ✓（离线时卡片上也不是空白 ✓）

## 阶段⑤（2026-10-11）：把她这句话写进桌面小组件那一行 ✓
## （两行文件：她的话 + unix 秒 ✓；写完让安卓侧刷一下 ✓。
##  ⚠️ 非安卓上 wrap 不出 PetBridge ✓ → 直接当"没有卡片" ✓，安静返回 ✓
##     （同 pet_mobile_battery._read_battery 的套路 ✓））
func _widget_note(text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	var f := FileAccess.open(WIDGET_FILE, FileAccess.WRITE)
	if f == null:
		return          # 写不进去就写不进去 ✓ —— 卡片显示上一句，不比没有更糟 ✓
	f.store_line(t)
	f.store_line(str(int(Time.get_unix_time_from_system())))
	f.close()
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return
	cls.refreshWidget()
	JavaClassWrapper.get_exception()      # 官方要求：调完必查 ✓

## 开始流式：清空对话框、把名字条摆好。之后 pet_chat_flow 会一段段 append_token 进来
func _begin_stream_bubble() -> void:
	if _bubble == null:
		return
	_bubble.text = ""
	_bubble.visible = true
	_ui.show_line("")
	_chat_streaming = true
	_bump_fps()

## 往对话记录里补一行：**内存那份给上下文用，落盘那份给"翻历史"用**（2026-10-08 起）
func _push_chat_line(who: String, text: String) -> void:
	_chat_history.append("%s：%s" % [who, text])
	while _chat_history.size() > 60:
		_chat_history.pop_front()
	_chatlog.append(who, text)       # 立刻落盘（调用点是"整句"处，不是流式的每一段 ✓）
	if OS.is_debug_build():
		print("[PetDeek] 对话：%s：%s" % [who, text])

# ------------------------------------------------------------------ 性能采样（只在 debug 包）
#
# 为什么放 app 里而不是用 adb 量：SurfaceFlinger --latency 要靠图层名，实测挑不准 ✗；
# 而"帧率低"这类问题必须**先量清楚是 GPU 还是 CPU**（脚本耗时 = CPU，绘制调用/顶点 = GPU 侧），
# 否则只能瞎调画质 ✗。这行只在 debug 包里出现，正式包一行输出都没有 ✓
#
# 判读：脚本耗时接近 16.7ms → CPU 卡（去查 _process 里的大头）；
#       脚本耗时很小而 fps 低 → GPU 卡（降 MSAA / scaling_3d / 阴影图尺寸）
var _perf_t := 0.0

func _perf_tick(delta: float) -> void:
	if not OS.is_debug_build():
		return
	_perf_t += delta
	if _perf_t < 5.0:
		return
	_perf_t = 0.0
	print("[PetDeek] 性能：%.1f fps（上限 %d）｜ 脚本 %.2f ms ｜ 绘制调用 %d ｜ 顶点 %d" % [
		Engine.get_frames_per_second(),
		Engine.max_fps,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	])

# ------------------------------------------------------------------ 触摸：点她 = 摸她（2026-10-08）
#
# 手上只有"点一下"这一种手势 —— 桌面上拖拽是"把窗口挪走"，手机上没有这个概念。
# 部位判定复用桌面的 pet_pointer.classify_touch（**静态函数**，直接取），
# 分寸（摸胸要明确不乐意、反复手欠会攒成生闷气）全在 pet_mood.gd，这里只管把点位翻成部位名。

## 按下时的位置。松手时看它挪了多远 → 远的是划动，不算点她
var _press_pos := Vector2.INF

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if t.pressed:
			_press_pos = t.position
		else:
			_release_at(t.position)
		return
	# ⚠️ Android 上手指按下会**同时**产生 ScreenTouch 和模拟鼠标事件
	# （input_devices/pointing/emulate_mouse_from_touch 默认是开的）→
	# 触摸屏在的时候就只认上面那条，否则一次点击会被算成摸两下，白白触发"摸太频繁"
	if DisplayServer.is_touchscreen_available():
		return
	# 下面这条是给"在编辑器/桌面窗口里跑这份工程"用的（开发时用鼠标试）
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_press_pos = mb.position
		else:
			_release_at(mb.position)

func _release_at(at: Vector2) -> void:
	if _press_pos == Vector2.INF:
		return
	# 设置页开着时这一下归 UI（遮罩是 MOUSE_FILTER_STOP，正常收不到；
	# 这条是给探针/代码直接调进来兜底）
	if _settings_ui.is_open():
		_press_pos = Vector2.INF
		return
	var moved := at.distance_to(_press_pos)
	_press_pos = Vector2.INF
	if moved > TAP_SLOP:
		return                      # 划过去的，不算点她
	var r := _char_screen_rect()
	if r.size.x <= 1.0 or r.size.y <= 1.0:
		return
	if not r.grow(20.0).has_point(at):
		# 点在空白处 → 不打扰她；但对话框开着的话，这一下就是"点一下继续"
		_ui.dismiss_dialog()
		return
	# ⚠️ 双击判定要挡在"摸她"**前面** ✗（阶段 11）：第二下不该再算一次摸头 ✓ ——
	# 不然她会先被连摸两下、再收到截图 ✓（台词、心情、动作全乱 ✓）
	var now := Time.get_ticks_msec()
	if now - _last_tap_ms <= DOUBLE_TAP_MS and at.distance_to(_last_tap_pos) <= DOUBLE_TAP_SLOP:
		_last_tap_ms = 0
		_shot_to_her()
		return
	_last_tap_ms = now
	_last_tap_pos = at
	var part: String = PetPointer.classify_touch((at - r.position) / r.size)
	_bump_fps()
	_ui.buzz()                      # 摸到了要有"摸到东西"的反馈，不然像在戳玻璃
	PetLog.log("触摸", "摸到 %s（%s）" % [part, _mood.describe_short()])
	_touch_react(part)

# ------------------------------------------------------------------ 双击她 = 截屏给她看（阶段 11）

## 双击判定：两下的间隔上限（毫秒 ✓）。手点两下一般 150~300ms ✓。
## ⚠️ 2026-10-10 从 350 放宽到 **420** ✗→✓（用户报的"双击没截图"✓）：手上节奏常比 350 慢一点 ✓，
## 第二下落在窗口外就被当成又一次单击 ✓（只是把弹着的对话框关了又开 ✓）→ 观感就是"怎么都没截到"✓。
## 420 仍远小于"两次真的单击"的间隔（人一般 500ms+ ✓），不会误判 ✗
const DOUBLE_TAP_MS := 420
## 两下之间手别挪太远（像素 ✓）—— 挪远了那是"摸头，再摸手" ✓，不是双击
const DOUBLE_TAP_SLOP := 60.0
## 上一次"点一下"的时刻（0 = 还没有 ✓）/ 位置
var _last_tap_ms: int = 0
var _last_tap_pos := Vector2.INF

## **双击她 → 把当前屏幕截一张发给她** ✓（阶段 11，2026-10-10 用户要的 ✓）
##
## 为什么值得补 ✗→✓：手机上一直没有"截屏那条" ✓ —— 桌面版她有个"偷看屏幕" ✓，
## 手机上只能靠主人**从相册挑一张**给她 ✓（阶段 5c）。双击这条把"主人不用挑"补上 ✓。
##
## ⚠️ 阶段 13（2026-10-10）：**开了无障碍就不弹框了** ✓ —— 见下面 `_a11y_shot_ready` ✓；
##   没开才回退系统那个"允许截屏吗" ✓（你点了「取消」她会自己说一句 ✓，
##   回话在 pet_mobile_share._check_shot_status ✓）。
##   截下来的图**走现成那条链** ✓：写进 `share_in.jpg` ✓ → 下一秒那条轮询交给她 ✓
##   （发送链一个字都没改 ✓ —— 换入口不换链路 ✓）
func _shot_to_her() -> void:
	PetLog.log("截屏", "双击她 → 截一张屏（%s）" % ("免授权 ✓" if _a11y_shot_ready() else "走系统授权框"))
	if _share.take_screenshot():
		_say("我看看你屏幕上是什么…")


## 阶段 13（2026-10-10）：**免授权截屏**（无障碍）现在开着吗 ✓
## （开着 → 双击随叫随截、不弹系统框 ✓；没开 → 每次弹一次 ✓）
## ⚠️ 读写都要查 `JavaClassWrapper.get_exception()` ✗（规矩见 pet_mobile_share.pick_from_gallery ✓）
func _a11y_shot_ready() -> bool:
	if OS.get_name() != "Android":
		return false
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return false
	var ready := bool(cls.isA11yShotReady())
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.warn("截屏", "查免授权截屏状态抛异常：%s" % str(ex))
		return false
	return ready


## 阶段 13：拉起系统「设置 → 无障碍」让用户自己去开 ✓
## ⚠️ 我们**只能把他送到门口** ✗ —— 那个开关必须用户自己点 ✓（这是安卓的规矩 ✓）
func _open_a11y_shot_settings() -> void:
	if OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return
	cls.openAccessibilitySettings()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.err("截屏", "拉起无障碍设置抛异常：%s" % str(ex))
		return
	PetLog.log("截屏", "已拉起系统「无障碍」设置页 ✓（进去把「桌宠截屏」打开 ✓）")

## 角色包围盒投影到**屏幕坐标**（抄 pet_pointer._char_screen_rect）。
## 手机上唯一要判的就是"手指有没有落在她身上"，所以直接用启动时量好的 _calib_aabb，
## 不必像桌面那样每帧重算（桌面那份要跟着窗口尺寸变）
func _char_screen_rect() -> Rect2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for i in 8:
		var world: Vector3 = _pivot.global_transform * _calib_aabb.get_endpoint(i)
		if _camera.is_position_behind(world):
			continue
		var p := _camera.unproject_position(world)
		minp = minp.min(p)
		maxp = maxp.max(p)
	if minp.x > maxp.x:
		return Rect2(vp * 0.5, Vector2.ZERO)
	return Rect2(minp, maxp - minp)

# ------------------------------------------------------------------ 宿主壳
# ⚠️ 下面这些名字**是模块契约**：pet_touch / pet_mood_ui / 以后的 pet_pointer 都是按
# 桌面那套老名字调进来的（`_touch_react` / `_play_action` / `_pick` / `go_idle`…），
# 改名不会编译不过，只会让它们在运行时找不到方法 —— 所以壳必须留（见 CONVENTIONS.md）

## 被摸到了（部位判定见上面 _release_at，分寸见 pet_mood.gd）
func _touch_react(part: String) -> void:
	_mood_ui.touch_react(part)

## 被理了就消气（聊天、摸头、喂食都算）
func _soothe() -> void:
	_mood_ui.soothe()

## 「哄哄她」：走和"被理了"同一条路 + 一句软话（阶段 3 的设置页会挂上这个按钮）
func _soothe_her() -> void:
	_mood_ui.soothe_her()

## 从一串台词里随手挑一句（模块里的台词组也走它）
func _pick_line(lines: Array) -> String:
	return _mood_ui.pick_line(lines)

## 设置页开关（界面层右上角那个⚙调它；探针也走这里）
## 四个全屏面板（设置页 / 聊天记录 / 记忆浏览 / 提醒事项）**互斥**：否则会叠在一起、遮罩互相压 ✗
func toggle_settings() -> void:
	_chatlog_ui.close()
	_memview_ui.close()
	_remind_ui.close()
	_settings_ui.toggle()

## 聊天记录页开关（界面层右上角「记录」调它；探针也走这里）
func toggle_chatlog() -> void:
	_settings_ui.close()
	_memview_ui.close()
	_remind_ui.close()
	_chatlog_ui.toggle()

## 记忆浏览页开关（设置页「她记得的事…」调它）
func toggle_memview() -> void:
	_settings_ui.close()
	_chatlog_ui.close()
	_remind_ui.close()
	_memview_ui.toggle()

## 提醒事项页开关（设置页「提醒事项…」调它；探针也走这里）
func toggle_remind() -> void:
	_settings_ui.close()
	_chatlog_ui.close()
	_memview_ui.close()
	_remind_ui.toggle()

## 心情变了 → 播一个"能体现这个情绪"的动作（动作表在 pet_mood_ui.MOOD_ACTIONS）
func _on_mood_changed(m: int) -> void:
	_bump_fps()
	PetLog.log("情绪", "心情变了 → %s" % _mood.describe_short())
	_mood_ui.on_mood_changed(m)

# ------------------------------------------------------------------ 动画收尾
# ⚠️ 名字是**模块契约**：`pet_rig._on_main_finished` 会读 `pet._state` / `pet._idle_anim`

## 一次性动作播完 → 回待机（实现在 pet_rig._on_main_finished）。
## 不接这个信号她就会僵在那个动作的最后一帧（2026-10-08 真机报的"动作不衔接"）
func _on_main_finished(name: String) -> void:
	rig._on_main_finished(name)

# ------------------------------------------------------------------ 动画壳（实现都在 pet_rig，和桌面同一套）

func _play_action(name: String, blend: float = 0.15, extra: float = 0.35) -> void:
	rig._play_action(name, blend, extra)

func _pick(names: Array, fallback: String) -> String:
	return rig._pick(names, fallback)

## 回到待机。**必须留在宿主**：State 是本脚本的枚举，模块在弱类型引用下取不到（见 CONVENTIONS.md）
func go_idle() -> void:
	_state = State.IDLE

## 播一个"持续姿势"：静态姿势动画**循环播** = 一直保持那个姿势（悲伤时蜷着）。
## 循环是关键 —— 0.001 秒的姿势动画不循环会瞬间 finished，被拉回待机（抄 desktop_pet）
func _play_pose_loop(name: String) -> void:
	if name == "" or not _has.has(name):
		return
	var a := _anim.get_animation(name)
	if a != null and a.loop_mode != Animation.LOOP_LINEAR:
		a.loop_mode = Animation.LOOP_LINEAR
	_anim.play(name, 0.25)
	_state = State.IDLE
	_timer = 9999.0

# ------------------------------------------------------------------ 生命周期尾巴

## 情绪落盘：Android 上**不能只等 _exit_tree** —— 用户从"最近任务"里划掉她时进程是直接没的，
## 所以"退到后台"那一刻就得存（PAUSED 一定会来）
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			# 退到后台：Android 会先把 surface 收走，这时候再满帧跑纯属白烧电
			Engine.max_fps = FPS_BACKGROUND
			_away_since_unix = Time.get_unix_time_from_system()   # 记下"她是哪一刻走的"（阶段 8 ✓）
			_save_mood("退到后台")
			_start_keepalive()                          # 阶段 9：后台保活（前台服务 + 喊话计时 ✓）
			_show_overlay()                             # 阶段 10：悬浮球（她浮在别的 App 上 ✓）
		NOTIFICATION_APPLICATION_RESUMED:
			Engine.max_fps = FPS_ACTIVE
			_active_left = IDLE_AFTER
			PetLog.log("生命周期", "回到前台（帧率回 %d）" % FPS_ACTIVE)
			_import_overlay_chat()                      # 阶段 10：悬浮窗里聊的并进记录 ✓
			_hide_overlay()                             # 阶段 10：收起悬浮球 ✓
			_stop_keepalive()                           # 阶段 9：收掉服务与那路静音音频 ✓
			_note_return()                              # 阶段 8：她知道你走开过 ✓
		NOTIFICATION_WM_CLOSE_REQUEST:
			_save_mood("关闭 App")

# ------------------------------------------------------------------ 阶段 10（2026-10-09）：悬浮球 + 气泡
#
# 用户要的 A 方案 ✓：**原生悬浮球**（Java 画的 ✓，见 PetOverlay.java）——
# 她不用在后台"活着"也能浮在别的 App 上 ✓；主动说话就以**气泡**冒在球旁边 ✓。
#
# 为什么必须是原生 View（不能是 Godot 画的）✗：主循环在后台是停的 ✓（阶段 9 实测 ✓）。
#
# 球的图像 = **她的正视图头像** ✓（用户明确要的 ✓）：在真机上用她**自己的模型**截一张 ✓
# （`_capture_face` ✓ → `user://pet_face.png` ✓ = Java 读的那个文件 ✓）。

## 头像文件（= Java 的 `files/pet_face.png` ✓）
const FACE_PATH := "user://pet_face.png"
## 悬浮窗里"打字聊天"用的人设快照（= Java 读的 `files/overlay_prompt.txt` ✓）
## ⚠️ 为什么要有它 ✗：那边是 Java 直接调模型 ✓，没法问 GDScript 要人设 ✓（引擎在后台是停的 ✓）。
## 所以**退后台那一刻**把系统提示词 + 最近几句 + 现在几点写下来 ✓ —— 只有这一份，两边话风就不会漂 ✓
const OVERLAY_PROMPT_FILE := "user://overlay_prompt.txt"
## 悬浮窗里聊过的那几行（Java 追加的 ✓）。回前台时**并进正式聊天记录**然后删掉 ✓
const OVERLAY_CHAT_FILE := "user://overlay_chat.txt"
## 头像边长（像素）✓。球本身在真机上是 182px ✓（52dp × 3.5 倍 ✓）——
## 所以 192 刚好够 ✓，再大纯属浪费内存（36 帧 × 256² 就是 9MB ✗）
const FACE_PX := 192
## 头像取景：方框边长 = **身高 × 这个倍**；中心 = 从头顶往下 **身高 × 下面那个倍** ✓
## ⚠️ 这两个数不是拍的，是**量**出来的（2026-10-10 用户："头居中当悬浮窗" ✓）：
##   真机整屏 1260×2800 上量到：她头顶（帽顶）y=454 ✓、身高 1596px ✓、
##   眼睛在 y≈878 —— 也就是 **头顶往下 0.266 倍身高** ✓。
##   取边长 0.46 倍、中心压到 0.245（略高于眼睛 ✓）：
##   于是**眼睛落在圆球正中那一带** ✓，帽子正好填满上面半个圆 ✓、
##   下巴和领结留在下沿 ✓（离线把整屏按这两条裁出来看过两版才定的 ✓）
const FACE_TOP_SPAN := 0.46
const FACE_TOP_CENTER := 0.245
## 方框中心落在**画面**里头顶往下多少（= 上面那条按倍率折算 ✓）。
## 之所以绕一道 ✗：上面的倍率是相对**身高**的 ✓，而下面量出来的是**像素行** ✓
const FACE_CENTER_IN_FRAME := FACE_TOP_CENTER / FACE_TOP_SPAN

# ---- 阶段 12（2026-10-10，用户要的）：让悬浮球"活"起来（眨眼 + 微微晃 ✓）----
## 待机那一圈截几帧 ✓
## ⚠️ 用户 2026-10-10 反馈"现在帧率太低了" ✓ —— 原来只 6 帧 ✓
## （每帧 399ms ≈ 2.5 帧/秒 ✗，看着就是幻灯片 ✓）。现在 36 帧、每帧 ~78ms ✓ = **13 帧/秒** ✓。
## 而且**多截不花时间** ✓：帧是用 `seek()` 定帧抓的 ✓（不是等真实时间过去 ✓），
## 所以"截 36 帧"跟"截 6 帧"走的是同一段动画时间 ✓，只是多读几次帧缓冲 ✓
const FACE_FRAMES := 36
## 眨眼要**逐格拨几格** ✓（拨得越密，"闭到底"那一格越容易被抓住 ✓、过渡也越顺 ✓）
const FACE_BLINK_SHOTS := 12
## 待机那一圈最多截到几秒为止 ✓（36 帧铺在 2.8 秒里 = 每帧 78ms ✓ = 13 帧/秒 ✓；
## ⚠️ 帧数固定时**跨度越长越卡** ✗ —— 想要更顺该加帧数，不是拉长跨度 ✓）
const FACE_WALK_LIMIT := 2.8
## 帧文件名 / 回话文件（Java 按同一套名字读 ✓，见 PetOverlay ✓）
const FACE_FRAME_TMPL := "user://pet_face_%d.png"
const FACE_BLINK_HALF := "user://pet_face_b0.png"
const FACE_BLINK_CLOSED := "user://pet_face_b1.png"
const FACE_MANIFEST := "user://pet_face_frames.txt"

## 悬浮球开不开（跟着设置走 ✓，见 pet_mobile_settings.overlay ✓）
var overlay_on := false
## 只在第一次遇到"没授权"时提醒一行 ✓（别每次退后台都刷 ✓）
var _overlay_warned := false

## 截一张她的**正视图头像** ✓（悬浮球用 ✓）
##
## ⚠️ 第一版我用"临时插一台正交相机去框头" ✗ —— 真机截出来是一张糊糊的灰方块 ✗
## （贴得过近，拍到的是她的皮肤/头发面 ✓，日志里"1260×2800 里取 1260 方形"就是它 ✓）。
## 现在换成**照着主相机自己算** ✓：
##   · 用 `Camera3D.unproject_position` 把"头顶那点"投到屏幕像素 ✓（主相机本来就是正面 ✓，
##     所以这样裁出来**必定是正视图** ✓，也不用插相机、不用动主相机 ✓）
##   · 再用同一个投影量一下**她整个有多高**（像素 ✓）→ 乘 `FACE_TOP_SPAN` 就是方框边长 ✓
##   · 方框**就从头顶那条线往下切** ✓（不再往下偏移 ✗）→ 头自然落在正中 ✓
## 这样取景完全跟着她实际在屏幕上的大小走 ✓（换模型/换分辨率都不会再拍空 ✓）
##
## ⚠️ 为什么要"从头顶往下 0.44"而不是"头 + 肩"（2026-10-10 用户："头居中当悬浮窗" ✓）✗：
##   上一版是取"头 + 肩"、方框比那段再大 1.25 倍、竖向上再往下挪 0.45 段 ✓ ——
##   于是**脸落在圆球下沿** ✓（真机截出来的图里脸在 65% 那一带 ✓），
##   圆球一裁下巴几乎压在下边缘上 ✗，看着就是"头没摆正" ✓。
##   现在按"她的头占身高 0.04~0.36、中心 0.20"这条**实测**来的比例取景 ✓，
##   方框（0.44 倍身高）的中心落在 0.22 —— 头基本居中、还略偏上一点（看着正好 ✓）
## ⚠️⚠️ **头顶那点必须先过 pivot 那道变换** ✗（2026-10-10 量出来的真 bug ✓）：
##   她的 pivot 被抬高了（`_frame_camera` 里 `_pivot.position.y = _ground_offset` ✓），
##   而 `_calib_aabb` 是**模型本地**的盒子 ✓ —— 上一版直接 `unproject_position(aabb的点)` ✗，
##   漏了 `_pivot.global_transform` ✓，于是裁剪框整体**偏低 66px** ✗：
##   帽顶被切掉一截 ✓，看着就像"头没摆正" ✓。
##   `_char_screen_rect`（判手指落在哪儿 ✓）一直是对的 ✓ —— 它乘了 pivot ✓，这里跟着它抄 ✓
func _capture_face() -> void:
	await get_tree().process_frame          # 等第一帧画出来 ✓（不然读回来是空的 ✗）
	if _camera == null or _calib_aabb.size.y <= 0.0:
		return
	var a := _calib_aabb
	var xf := _pivot.global_transform
	var top: Vector3 = xf * Vector3(a.position.x + a.size.x * 0.5,
		a.position.y + a.size.y, a.position.z + a.size.z * 0.5)
	var foot: Vector3 = xf * Vector3(a.position.x + a.size.x * 0.5,
		a.position.y, a.position.z + a.size.z * 0.5)
	# "身高"用**头顶到脚底**量 ✓（比只量一段准 ✓）——
	# 换成一段来估的话，缩放一变、或她站得靠边一点，比例就会漂 ✗
	var p_top := _camera.unproject_position(top)
	var p_foot := _camera.unproject_position(foot)
	var h := maxf(40.0, absf(p_foot.y - p_top.y))         # 她整个有多高（像素 ✓）
	# ⚠️ **要等到帧缓冲真的有内容**（真机第四版才稳 ✓）：
	#   启动头两帧读回来是**空的** ✗（前几版都是 0.3 KB 的纯色 ✓，坐标明明是对的 ✓）。
	#   所以这里每 0.15 秒试一次、最多约 3 秒 ✓，用"采样点里有没有多种颜色"判它画出来没有 ✓
	var img: Image = null
	for i in 20:
		await get_tree().create_timer(0.15).timeout
		var t := get_viewport().get_texture().get_image()
		if t != null and not t.is_empty() and _image_has_content(t):
			img = t
			if i > 0:
				PetLog.log("悬浮球", "头像取景：等了 %d 轮才拿到有内容的画面 ✓" % (i + 1))
			break
	if img == null:
		PetLog.warn("悬浮球", "截头像失败：等了 3 秒画面还是空的 ✗（启动期帧缓冲没内容 ✓）")
		return
	# ⚠️⚠️ **这两个坐标系不一样，必须换算** ✗（真机第三版才抓到的 ✓）：
	#   `unproject_position` 给的是**设计空间**的坐标（这台是 450×1000 ✓ —— project 开了
	#   content_scale ✓，Control 空间就是设计分辨率 ✓），而 `get_image()` 读回来的是
	#   **真实帧缓冲**（1260×2800 ✓，2.8 倍 ✓）。
	#   直接拿设计坐标去裁真实图 = 裁到左上角的一块背景 ✗
	#   —— 日志里"取 (90, 141) 起 320 方形"就是它 ✓，难怪前两版都是 0.3 KB 的纯色 ✗
	var vis := get_viewport().get_visible_rect().size
	var k := Vector2(img.get_size()) / vis if vis.x > 0.0 and vis.y > 0.0 else Vector2.ONE
	var side := int(h * FACE_TOP_SPAN * k.y)
	var cx := int(p_top.x * k.x)                           # 横向以她自己的中线为准 ✓
	# 竖向：**头顶那条线从画面里量** ✓（算出来的那个不准 —— 见 _find_head_top ✓），
	# 中心再往下压 0.53 个方框 ✓ —— 眼睛正好落在圆球正中那一带 ✓
	var top_y := int(p_top.y * k.y)
	var measured := _find_head_top(img, top_y)
	if measured > 0:
		top_y = measured
	var cy := top_y + int(side * FACE_CENTER_IN_FRAME)
	# 横向同样**照画面量** ✓（包围盒的中线不等于她脸的中线 —— 见 _find_face_center ✓）
	var face_x := _find_face_center(img, top_y, side, cx)
	if face_x > 0:
		cx = face_x
	# 夹进画面 ✓（她靠边、或者方框超出上下时别裁出去 ✓）
	side = mini(side, mini(img.get_width(), img.get_height()))
	cx = clampi(cx, side / 2, img.get_width() - side / 2)
	cy = clampi(cy, side / 2, img.get_height() - side / 2)
	if side < 24:
		PetLog.warn("悬浮球", "头像取景算不出来 ✗（边长太小：%d）" % side)
		return
	var box := Rect2i(cx - side / 2, cy - side / 2, side, side)
	PetLog.log("悬浮球", "头像取景 ✓（图 %dx%d ｜ 设计空间 %.0fx%.0f → 倍率 %.1f ｜ 头顶：算 %d ／ 量 %d ｜ 中线：算 %d ／ 量 %d ｜ 取 (%d, %d) 起 %d 方形）" % [
		img.get_width(), img.get_height(), vis.x, vis.y, k.x,
		int(p_top.y * k.y), top_y, int(p_top.x * k.x), face_x,
		box.position.x, box.position.y, side])
	# 老名字那张也留着 ✓：Java 万一一帧都没读到 ✓，就退回这张**静止的她** ✓
	var first := _face_square(img, box)
	if first.save_png(FACE_PATH) != OK:
		PetLog.warn("悬浮球", "头像存不下来 ✗（%s）" % FACE_PATH)
	# 阶段 12：多截几帧 → 球会眨眼、会微微晃 ✓（Java 轮着播 ✓）
	await _capture_face_frames(box, first)

## 从画面里量"她的头顶在哪一行"（像素行 ✓；量不到返回 -1 ✓）
##
## ⚠️ 为什么不能只用算出来的那个 ✗（2026-10-10 量出来的）：
##   把整屏 1260×2800 逐点量了一遍 —— 她的**帽顶在 y=454** ✓，
##   而 `unproject_position(包围盒顶)` 给的是 **521** ✗，整整差 67px ✓
##   （同一台机、两次构建、两次都是这个差值 ✓，**不是动画抖动** ✗）。
##   也就是说 `_calib_aabb` 顶上比画出来的她**矮了一截** ✓
##   （顺带一提：手指判定的那个矩形也因此偏短 ✓ —— 那是另一件事，没在这儿动 ✗）。
##   与其在包围盒上贴一个"补偿 67px"的魔数 ✗，不如**就照画面量** ✓ ——
##   帽子/脸是她身上最亮的那一大块 ✓，从算出来的位置**往上一点点开始往下扫**，
##   第一条"够亮"的行就是帽顶 ✓；旁边是暗背景 ✓、上面是空背景 ✓，不会认错 ✓
func _find_head_top(img: Image, from_y: int) -> int:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := maxi(0, int(w * 0.30))
	var x1 := mini(w, int(w * 0.70))          # 只看她身体中间那条竖带 ✓（避开右上角那些图标 ✓）
	var step := 12
	var need := maxi(4, int((x1 - x0) / step * 0.25))    # 一行里够亮的采样点下限 ✓
	var y := maxi(0, from_y - 150)
	var y_end := mini(h, from_y + 100)
	while y < y_end:
		var bright := 0
		var x := x0
		while x < x1:
			var c := img.get_pixel(x, y)
			if 0.3 * c.r + 0.59 * c.g + 0.11 * c.b > 0.55:
				bright += 1
			x += step
		if bright >= need:
			return y
		y += 2
	return -1

## 从画面里量"她的脸在哪一列"（像素列 ✓；量不到返回 -1 ✓）
##
## ⚠️ 为什么横向也得量 ✗（2026-10-10 量出来的）：
##   `p_top.x` 是**包围盒**的中线 ✓，而包围盒含双臂和裙摆 ✓、
##   也不一定和模型原点对齐 ✓ —— 实测真机两张头像里，她的脸都比框中心**偏左 25/256** ✓
##   （约 10% ✓，在 52dp 的小球上看得出来 ✓）。
##   同一个办法：**就照画面量** ✓ ——
##   在**脸那几行**（方框 0.42~0.70 那一段 ✓）里，皮肤/帽子是亮的 ✓、
##   两侧头发和背景都是暗的 ✓ → 亮点横坐标的均值就是脸的中线 ✓
##   亮点太少就不敢用 ✓（返回 -1，让她留着算出来的那个 ✓）
func _find_face_center(img: Image, top_y: int, side: int, cx_guess: int) -> int:
	var y := maxi(0, top_y + int(side * 0.42))
	var y_end := mini(img.get_height(), top_y + int(side * 0.70))
	var x0 := maxi(0, cx_guess - side / 2)
	var x1 := mini(img.get_width(), cx_guess + side / 2)
	var sum := 0
	var n := 0
	while y < y_end:
		var x := x0
		while x < x1:
			var c := img.get_pixel(x, y)
			if 0.3 * c.r + 0.59 * c.g + 0.11 * c.b > 0.55:
				sum += x
				n += 1
			x += 3
		y += 3
	if n < 30:
		return -1
	return int(float(sum) / float(n))

# ------------------------------------------------------------------ 阶段 12：一串帧（眨眼 + 微微晃）

## 给悬浮球**截一串帧** ✓（用户要的"眨眼 / 微微晃动" ✓）
##
## 为什么只能这么干 ✗→✓：球是 **Java** 画的 ✓（引擎一退后台就停 ✓，见头部第 9 条），
## 它没法"实时看她的模型" ✗ —— 但帧**可以在启动时先截好** ✓，Java 那边轮着播就行 ✓。
##
## 晃得对：按**待机动画一整圈**均分取样 ✓（读 `Animation.length` ✓）——
##   一圈首尾相接 ✓，Java 循环播时接缝处不会"跳一下" ✓；一圈太长就只截前 2.4 秒 ✓
## 眨得准：`rig._blink()` 是**现成的口子** ✓（桌面那句随机眨眼走的就是它 ✓）——
##   命令她眨一下、然后 0.5 秒里连拍 ✓，再**量**哪几帧真闭了眼 ✓（见 _eye_diff ✓），
##   不靠猜 ✓。挑两张存下来：半闭 ✓ / 闭 ✓（Java 那边就是"半闭→闭→半闭"一闪 ✓）
func _capture_face_frames(box: Rect2i, first: Image) -> void:
	# 先清掉上一次留下的帧 ✗ —— 这次要是只截到 4 帧，旧的 pet_face_5.png
	# 会被 Java 当成"第 5 帧"接着播 ✓（序列宁可短，不可脏 ✓）
	for i in 24:
		DirAccess.remove_absolute("user://pet_face_%d.png" % i)
	DirAccess.remove_absolute(FACE_BLINK_HALF)
	DirAccess.remove_absolute(FACE_BLINK_CLOSED)
	DirAccess.remove_absolute(FACE_MANIFEST)

	# ① 待机那一圈 ✓（第 0 帧就是上面那张 ✓，不重截 ✓）
	#
	# ⚠️ **按时间逐格拨**，而不是"等真实时间过去" ✗（2026-10-10 看两张图看出来的）：
	#   第一版是真等 dt 再抓 ✓，结果眨眼那几格落在**另一个晃动相位**上 ✓ ——
	#   球一眨眼，她的头会**往上跳一大截** ✗（睁/闭两张一比就看出来 ✓）。
	#   现在把身体动画**冻住** ✓、用 `seek()` 一格格定姿势 ✓：
	#   每格都是"确切的第几秒" ✓，眨眼那几张也对齐到第 0 格那个姿势 ✓✓
	var dt := 0.2
	var idle_len := 0.0
	var frozen := false
	if _anim != null and _idle_anim != "":
		var a := _anim.get_animation(_idle_anim)
		if a != null and a.length > 0.05:
			idle_len = a.length
			# 下限 60ms ✓（17 帧/秒就够顺了 ✓，再快手机也画不出来 ✓）
			dt = clampf(a.length / float(FACE_FRAMES), 0.06, FACE_WALK_LIMIT / float(FACE_FRAMES))
		_anim.play(_idle_anim, 0.0)
		_anim.speed_scale = 0.0
		frozen = true
	var saved := 0
	if first.save_png(FACE_FRAME_TMPL % 0) == OK:
		saved = 1
	for i in range(1, FACE_FRAMES):
		if frozen:
			_anim.seek(dt * float(i), true)
			await get_tree().process_frame
			await get_tree().process_frame
		else:
			await get_tree().create_timer(dt).timeout
		var img := await _grab_screen()
		if img == null:
			break
		var f := _face_square(img, box)
		if f.save_png(FACE_FRAME_TMPL % i) != OK:
			break
		saved += 1
	if saved < 2:
		PetLog.warn("悬浮球", "帧序列没截够 ✗（只拿到 %d 帧）→ 球还是那张静止的 ✓" % saved)
		return

	# ② 命令她眨一下 —— **逐格定帧** ✓（比"抢时机抓拍"准得多 ✓）
	#
	# ⚠️ 第一版是"连拍抢时机" ✗，真机量出来 6 张的差值 0.048~0.054 几乎一样 ✓ ——
	#   那差值量到的是**她在呼吸晃动** ✗，根本没抓到闭眼 ✓。
	#   现在改成：把两个 player **都冻住**（speed_scale = 0 ✓）——
	#   身体不动了 ✓，再把这套眨眼动画一格格 `seek()` 过去 ✓，
	#   于是眼睛那一带的变化**只可能来自眨眼** ✓，量出来就干净 ✓
	var shots: Array = []
	var blink_n := 0
	if rig != null and _anim_face != null:
		var keep_body := 0.7
		if _anim != null:
			keep_body = _anim.speed_scale
			_anim.speed_scale = 0.0
		var keep_face := _anim_face.speed_scale
		_anim_face.speed_scale = 0.0
		rig._blink()
		var bname := String(_anim_face.current_animation)
		# ⚠️ `rig._blink()` 里带 0.05 的过渡 ✓ —— 冻结状态下会卡在过渡中间 ✗，重放一次、不要过渡 ✓
		_anim_face.play(bname, 0.0)
		var blen := 0.9
		var banim := _anim_face.get_animation(bname)
		if banim != null and banim.length > 0.05:
			blen = banim.length
		for i in FACE_BLINK_SHOTS:
			_anim_face.seek(blen * float(i) / float(maxi(1, FACE_BLINK_SHOTS - 1)), true)
			await get_tree().process_frame
			await get_tree().process_frame
			var img := await _grab_screen()
			if img == null:
				continue
			var f := _face_square(img, box)
			# 第 0 格（t=0，眼睛还睁着 ✓）当参考 ✓；后面的差值就是"闭上了多少" ✓
			var ref: Image = shots[0]["img"] if shots.size() > 0 else f
			shots.append({"img": f, "d": _eye_diff(ref, f)})
		if frozen:
			# 松开她 ✓（速度回到宿主那个 0.7 ✓ —— 别写死 ✗，那是检查器参数 ✓）
			_anim.speed_scale = anim_speed
		_anim_face.speed_scale = keep_face
		_anim_face.play("idle_face")
	if shots.size() >= 3:
		# 差值最大的那格 = 闭得最实 ✓；其余里最接近"一半"的 = 半闭 ✓（都是量出来的 ✓）
		var bi := 0
		for k in shots.size():
			if float(shots[k]["d"]) > float(shots[bi]["d"]):
				bi = k
		var hi := -1
		var gap := 1e9
		for k in shots.size():
			if k == bi:
				continue
			var g: float = absf(float(shots[k]["d"]) - float(shots[bi]["d"]) * 0.5)
			if g < gap:
				gap = g
				hi = k
		# ⚠️ 差值太小 = 她压根没闭上（或者这套动画里本来就没有闭眼 ✓）→ 那就**不硬编** ✗
		if float(shots[bi]["d"]) > 0.02:
			shots[bi]["img"].save_png(FACE_BLINK_CLOSED)
			blink_n = 1
			if hi >= 0:
				shots[hi]["img"].save_png(FACE_BLINK_HALF)
				blink_n = 2
	var diffs := ""
	for k in shots.size():
		diffs += "%.3f " % float(shots[k]["d"])
	PetLog.log("悬浮球", "眨眼：逐格拨了 %d 格，眼睛那块的差值 %s→ 存下 %d 张 ✓" % [
		shots.size(), diffs, blink_n])
	# ③ 给 Java 留一张小清单 ✓（几张 ✓ + 每张停多久 ✓ + 眨眼几张 ✓）
	var mf := FileAccess.open(FACE_MANIFEST, FileAccess.WRITE)
	if mf != null:
		mf.store_line("%d %d %d" % [saved, int(dt * 1000.0), blink_n])
		mf.close()
	PetLog.log("悬浮球", "帧序列已备好 ✓（待机 %d 帧 ｜ 一圈 %.1f 秒里截了 %.1f 秒 ｜ 每帧 %d ms ｜ 眨眼拨 %d 格 → 存 %d 张）" % [
		saved, idle_len, dt * float(saved), int(dt * 1000.0), shots.size(), blink_n])

## 按取景框裁一张、缩到球的尺寸 ✓（**不落盘** ✓ —— 先量差值，挑出来的才存 ✓）
func _face_square(img: Image, box: Rect2i) -> Image:
	var sq := img.get_region(box)
	sq.resize(FACE_PX, FACE_PX, Image.INTERPOLATE_LANCZOS)
	return sq

## 抓一帧完整画面 ✓（拿不到"有内容"的帧就返回 null ✓）
func _grab_screen() -> Image:
	for i in 12:
		var t := get_viewport().get_texture().get_image()
		if t != null and not t.is_empty() and _image_has_content(t):
			return t
		await get_tree().create_timer(0.05).timeout
	return null

## 两张头像**眼睛那一块**差多少 ✓（0 = 一模一样 ✓）—— 用来量"她闭没闭眼" ✓
## ⚠️ 只比眼睛那一条带 ✗：她整个身子都在呼吸晃动 ✓，整张比会把晃动也算进去 ✓；
## 而眼睛是亮蓝色、闭上成了肤色 ✓ —— 那一带的变化比晃动大得多 ✓
func _eye_diff(a: Image, b: Image) -> float:
	if a == null or b == null:
		return 0.0
	var w := mini(a.get_width(), b.get_width())
	var h := mini(a.get_height(), b.get_height())
	if w <= 4 or h <= 4:
		return 0.0
	var sum := 0.0
	var n := 0
	var y := int(h * 0.36)
	while y < int(h * 0.66):
		var x := int(w * 0.22)
		while x < int(w * 0.78):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf((0.3 * ca.r + 0.59 * ca.g + 0.11 * ca.b)
				- (0.3 * cb.r + 0.59 * cb.g + 0.11 * cb.b))
			n += 1
			x += 2
		y += 2
	return sum / maxf(1.0, float(n))

## 这张画面"有内容"没有 ✓：稀疏采一波点，看到 ≥3 种颜色就算画出来了 ✓
## （纯色 = 还没渲染 / 全黑 ✓ —— 真机上启动头几帧就是这样 ✗）
func _image_has_content(img: Image) -> bool:
	var seen := {}
	var w := img.get_width()
	var h := img.get_height()
	for i in 8:
		for j in 8:
			var px := img.get_pixel(int(w * (i + 0.5) / 8.0), int(h * (j + 0.5) / 8.0))
			seen[px.to_rgba32()] = true
			if seen.size() >= 3:
				return true
	return false

## 显示悬浮球 ✓（只在"设置里开着 + 拿到授权"时真显示 ✓；没授权就记一行 ✓）
func _show_overlay() -> void:
	if not overlay_on or OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return
	if not bool(cls.canDrawOverlay()):
		_overlay_warn_once()
		return
	cls.showOverlay()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.err("悬浮球", "显示时抛异常：%s" % str(ex))
		return
	# ⚠️ **必须问一句"真的挂上去了吗"** ✗ —— Java 那边是 post 到 UI 线程的 ✓（异步 ✓），
	#    等一帧不够（真机 13:06 那轮就是这么误报"没挂上去"的 ✓）→ 改成**每 0.6 秒确认一次、最多 4 次** ✓：
	#    没挂上就再喊一次 ✓（UI 线程总有一天轮到 ✓）。日志里也会写清是第几次确认到的 ✓
	for i in 4:
		await get_tree().create_timer(0.6).timeout
		if not is_inside_tree():
			return
		if bool(cls.isOverlayShown()):
			PetLog.log("悬浮球", "已显示 ✓（第 %d 次确认到 ✓ 她浮在别的 App 上 ✓）" % (i + 1))
			return
		cls.showOverlay()          # 再喊一次 ✓
	PetLog.warn("悬浮球", "喊了 4 次还没挂上去 ✗ —— 看 logcat 里 `PetOverlay` 那几行（授权 / Activity ✓）")

## 收起悬浮球 ✓（你回到她跟前了，球就是多余的 ✓）
## ⚠️ 这里**必须有日志** ✗ —— 之前它是静默的 ✓，于是"用户看不见球"时
## 完全没法判断是"没显示出来"还是"显示完立刻被收掉了" ✓（2026-10-09 就卡在这儿 ✓）
func _hide_overlay() -> void:
	if OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls != null:
		# ⚠️ 先问一句"她真的在屏幕上吗" ✗ —— 真机实测：按 HOME 之后还会来一次**假的 RESUMED** ✓，
		#    不加这道判断的话，球刚显示 1 秒就被收掉 ✓（日志里 20:06:14 显示 → 20:06:15 收起 ✓）
		if not bool(cls.isAppVisible()):
			PetLog.log("悬浮球", "收到「回到前台」，但她其实还在别的 App 上 → 球留着 ✓")
			return
		# ⚠️ 再等 1.5 秒**确认一次** ✗ —— 这台（vivo）连 `hasWindowFocus` 都会在假 resume 里骗人 ✓：
		#    第一次判断说"她回前台了" ✓，可一秒钟后其实还在别的 App 上 ✓（真机 13:04 那轮就是这么丢的 ✓）。
		#    真回来的人扛得住这 1.5 秒 ✓，假 resume 扛不住 ✓✓
		await get_tree().create_timer(1.5).timeout
		if not is_inside_tree() or not bool(cls.isAppVisible()):
			PetLog.log("悬浮球", "刚才那次是假 resume（1.5 秒后她还在别的 App 上）→ 球留着 ✓")
			return
		cls.hideOverlay()
		var ex = JavaClassWrapper.get_exception()      # 调完必查 ✓
		if ex != null:
			PetLog.warn("悬浮球", "收起时抛异常：%s" % str(ex))
			return
		PetLog.log("悬浮球", "收起 ✓（她真回到前台了 ✓）")

func _overlay_warn_once() -> void:
	if _overlay_warned:
		return
	_overlay_warned = true
	PetLog.warn("悬浮球", "还没拿到「显示在其他应用上层」授权 ✗ —— 在设置页把「悬浮球」那一行勾上、去授权 ✓")

## 拉起系统那个悬浮窗授权页 ✓（设置页勾上「悬浮球」时调 ✓）
func _request_overlay_permission() -> void:
	if OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return
	cls.requestOverlayPermission()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.err("悬浮球", "拉起授权页时抛异常：%s" % str(ex))
		return
	PetLog.log("悬浮球", "已拉起悬浮窗授权页 ✓（允许之后，退到后台就能看到她浮着 ✓）")

## 阶段 9b 收尾（2026-10-11）：电池优化白名单现在允许了吗 ✓
## （`PowerManager.isIgnoringBatteryOptimizations` ✓；非安卓 / 查不了 → false ✓）
func _battery_whitelist_ready() -> bool:
	if OS.get_name() != "Android":
		return false
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return false
	var ready := bool(cls.isIgnoringBatteryOptimizations())
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.warn("保活", "查电池白名单状态抛异常：%s" % str(ex))
		return false
	return ready

## 阶段 9b 收尾（2026-10-11）：拉起系统那个"允许忽略电池优化"的对话框 ✓
## ⚠️ 用户点"不允许"也完全没关系 ✓ —— 前排那条前台服务已经解了 freezer 那件事 ✓，
##    这只是防国产 ROM 的省电策略再顺手按她 ✓（定位是第二道保险 ✓）
func _open_battery_whitelist() -> void:
	if OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return
	cls.requestIgnoreBatteryOptimizations()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		PetLog.err("保活", "拉起电池白名单对话框抛异常：%s" % str(ex))
		return
	PetLog.log("保活", "已拉起电池白名单对话框 ✓（允许之后省电策略不再按她 ✓）")

# ------------------------------------------------------------------ 阶段 9（2026-10-09）：后台保活
#
# 目标：她退到后台**还活着** ✓（能自己开口、能看一眼摄像头 ✓ —— 桌面那边她本来就是这样 ✓）。
#
# 为什么光有前台服务不够（这是本次最不确定的一条 ✓）：
#   实测（2026-10-09）：一按 HOME，主循环就被系统暂停 ✗ ——
#   150 秒里「每 1 分钟看一眼」一次都没触发 ✗、本地台词也没有 ✗。
#   前台服务按住的是**进程** ✓，而"跑不跑帧"是 Godot 那边的判断 ✓；
#   Godot 的移动端惯例是：**音频还在播的时候不把主循环整个停死** ✓。
#   所以这里再加一路**静音音频** ✓（`_keepalive_audio` ✓）——
#   它到底成不成立，本次要真机实测 ✓：看那 4 分钟里临时心跳还打不打 ✓。
#   不成立的话，这条就得换成"闹钟式台词通知"（见头部计划表的 B 方案 ✓），我会如实说 ✗。
#
# 两样都**只在退到后台时**开 ✓、回前台立刻收 ✓ —— 平时不留常驻通知、也不占着音频焦点 ✓
# （静音流一直挂着会去抢音频焦点，把你的音乐压掉 ✗，这个坑不值得踩 ✓）
#
# ── 实测结论（2026-10-09 真机 ✓）：**A 方案不成立** ✗ ────────────────────────
#   跑出来的事实（240 秒，不可辩驳 ✓）：
#     · Java 侧成功 ✓ —— `保活: 前台服务已启动（mediaPlayback）` ✓、通知渠道建出来了 ✓、
#       进程自始至终活着（pid 没变 ✓）
#     · Godot 侧失败 ✗ —— 心跳**一次都没打** ✗、相机日志没有 ✗、她一句话也没有 ✗
#   → 前台服务按住的是**进程** ✓，而"跑不跑帧"是引擎自己的决定 ✗ ——
#     那路静音音频当时已经在播（日志里写着"在播 ✓"）也照样没用 ✓。
#     也就是说：**安卓上没法用前台服务把 Godot 的主循环救活** ✗。
#   → 所以这里默认**关着** ✓：一条白挂的常驻通知没有任何好处 ✓，代码留着等换路 ✓。
#     还能走的两条（换路时再开这个开关 ✓）：
#       · **画中画（PiP）**：她缩成小窗浮在别的 App 上 ✓ —— Activity 保持 resumed、
#         主循环照跑 ✓（唯一能让"她真的还活着"的路 ✓，代价是屏幕上多一个小窗 ✓）
#       · **闹钟式台词通知**：零常驻 ✓，到点由系统拉起一下、从台词池挑一句发通知 ✓
#         （她不能思考、不发模型请求 ✓，但"她偶尔喊你一下"是成立的 ✓）
## ⚠️ 开关：false = 不拉服务、不挂通知；true = 退后台时挂常驻通知（也顺带解开上面那条冻结死结 ✓）
## 用户 2026-10-09 要求「后台通知框常驻」✓ → 打开 ✓。打开它**不止是多一条通知** ✗ ——
## 前台服务一旦在跑，应用就不进 `cached/frozen` 那档 ✓ → 被系统押住的 Job/闹钟**就会真的投递** ✓
##（实测：冻结时 `dumpsys alarm` 写 `Reason=frozen` ✗、Job 的 `TIMING_DELAY` 永远不满足 ✗）。
## 回前台时服务会被收掉 ✓（你正看着她，通知栏那条就没意义了 ✓）。
const KEEPALIVE_ENABLED := true

# ── 阶段 9b（2026-10-09）：**闹钟式台词通知** —— 这半是真能成的 ✓ ─────────────
#
# 她不需要在后台"活着"也能喊你一声 ✓：退后台那一刻由我们（引擎还活着 ✓）写下几句台词 ✓、
# 让系统到点唤醒一个接收器 ✓（`PetNotifyReceiver.java` ✓）把其中一句发成通知 ✓。
# 不需要主循环 ✓、不需要前台服务 ✓、不需要任何额外权限 ✓
# （闹钟用的是 inexact 的 setAndAllowWhileIdle ✓ —— 不碰精确闹钟那套授权 ✗）。
#
# ⚠️ 如实说清楚的一点：后台那几声是**照本子念**的 ✗ —— 引擎在后台是停的 ✓，
# 她没法思考 ✓。所以台词我只写三句、都是"你走开了"这件事本身 ✓，不编场景 ✗
# （编了就是"瞎说话"，今天刚在摄像头那边吃过这个亏 ✓）。

## 她"留话"用的小池子 ✓（三句，够两声闹钟 + 一句富余 ✓）
const LINES_NUDGE: Array[String] = [
	"……你是不是把我放兜里忘了。",
	"我在这儿站了一会儿了。你忙你的，我就说一声。",
	"人走了，屏幕还亮着。我看着呢。",
]
## 走开多久之后喊第一声 / 第二声（秒 ✓）。和主动说话那条的节奏对齐（普通档 5~15 分钟 ✓），
## 但**只喊两声** ✓ —— 后台通知比前台气泡扰人得多 ✓，多了就成骚扰 ✗
const NUDGE_AFTER_SEC: Array[float] = [20.0, 40.0]       # ⚠️ 调试值（用户 2026-10-09：再压一点、好调 ✓）；正式值 = 900 / 2700 ✓
## 台词文件（`user://` = 应用私有目录 ✓，Java 那边读的是同一个 `files/` ✓）
const NUDGE_FILE := "user://keepalive_lines.txt"

## 阶段⑤（2026-10-11，用户要的"桌面小组件"）：她最近那句话落在这儿 ✓
## （两行：第一行是她的话、第二行是 unix 秒 ✓；Java 侧 PetWidget 读它渲染 ✓。
##  ⚠️ 文件名和 PetWidget.LINE_FILE 逐字一致 ✗ —— 改一头必须改另一头 ✓）
const WIDGET_FILE := "user://widget_line.txt"

## 现在是不是"挂了后台那一套"状态（回前台要收干净 ✓）
var _keepalive := false
## 那路静音音频（在 _ready 里就建好 ✓ —— 别等到 PAUSED 那一刻才往树里加节点 ✓）
var _keepalive_audio: AudioStreamPlayer = null


## 建那路静音音频：0.1 秒、16 位、单声道、全是 0 ✓（耳朵上完全听不见 ✓）
## 用代码生成而不是带一个 wav 文件 ✓ —— 它就是个开关，不该变成一个资源 ✓
func _build_keepalive_audio() -> void:
	if _keepalive_audio != null:
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 8000
	wav.stereo = false
	var frames := 800                       # 8000Hz × 0.1s ✓
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)                # 16 位单声道 = 2 字节/帧 ✓；全 0 = 静音 ✓
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = frames
	_keepalive_audio = AudioStreamPlayer.new()
	_keepalive_audio.name = "KeepAliveAudio"
	_keepalive_audio.stream = wav
	_keepalive_audio.volume_db = -80.0      # 再保险一层：数据本来就是 0 ✓
	add_child(_keepalive_audio)

## 退到后台：静音音频开播 + 拉起前台服务 ✓（安卓把这一对认成"她在后台干活" → 不冻结进程/循环 ✓）
func _start_keepalive() -> void:
	if _keepalive:
		return
	_keepalive = true
	# ① 留话（这一步不依赖引擎在后台活着 ✓ —— 引擎此刻还活着 ✓）
	#    顺带拿回四格到点延时（秒，0 = 这一格空着 ✓）—— 台词文件行序 = 时间序 ✓
	var delays: Array = _write_nudge_lines()
	_write_overlay_prompt()          # 阶段 10：给悬浮窗里的"打字聊天"留一份人设快照 ✓
	if not KEEPALIVE_ENABLED:
		# 没有前台服务时，只能把"到点"交给系统调度器 ——
		# 实测在国产 ROM 上会被压住 ✗（frozen / TIMING_DELAY ✓），聊胜于无 ✓
		_schedule_nudges()
		return
	# ② 有前台服务：**计时交给服务自己** ✗✓（阶段 9c）——
	#    服务在跑的进程本身就是活的 ✓，`postDelayed` 比任何系统调度器都靠得住 ✓
	var audio_on := false
	if _keepalive_audio != null and not _keepalive_audio.playing:
		_keepalive_audio.play()
	audio_on = _keepalive_audio != null and _keepalive_audio.playing
	var svc := ""
	if OS.get_name() == "Android":
		var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
		if cls != null:
			# 阶段 9c：两个"喊一声"的延时一起带进去 ✓（服务自己 postDelayed ✓）
			# 阶段 9b 收尾（2026-10-11）：提醒事项的两格也一起 ✓ —— 四格就是
			# 台词文件前四行的到点时间 ✓（行序 = 时间序，见 _write_nudge_lines ✓）
			cls.startKeepAlive(
				int(float(delays[0]) * 1000.0), int(float(delays[1]) * 1000.0),
				int(float(delays[2]) * 1000.0), int(float(delays[3]) * 1000.0))
			var ex = JavaClassWrapper.get_exception()      # 官方要求：调完必查 ✓
			svc = "已请求 ✓" if ex == null else ("抛异常 ✗ " + str(ex))
		else:
			svc = "wrap 不出 PetBridge ✗"
	else:
		svc = "非安卓，跳过 ✓"
	PetLog.log("保活", "退到后台：静音音频 %s ｜ 前台服务 %s" % [
		"在播 ✓" if audio_on else "没播起来 ✗", svc])

## 回到前台：收干净 ✓（音频停 → 服务停 → 常驻通知消失 ✓）
func _stop_keepalive() -> void:
	if not _keepalive:
		return
	_keepalive = false
	# ① 撤掉还没响的闹钟 ✓ + 清掉没喊完的台词 ✓
	#（不撤的话你刚回来她还追着喊 ✗；回来再看到"你是不是把我忘了"更怪 ✗）
	if OS.get_name() == "Android":
		var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
		if cls != null:
			cls.cancelNudges()
			var ex = JavaClassWrapper.get_exception()
			if ex != null:
				PetLog.warn("喊一声", "撤销闹钟时抛异常：%s" % str(ex))
	# ⚠️ **别在回前台时删台词文件** ✗（2026-10-09 真机踩到）：
	# 那次中途来了一下 resume（`已撤销所有 Job` ✓），文件被删掉 ✓，
	# 结果后面两次"到点"都只能说"台词用完了" ✗（日志原话 ✓）。
	# 而且根本不需要删：每次退后台 `_write_nudge_lines()` 都会**整份重写** ✓，
	# 没到点的喊话也已经被撤销了 ✓ → 留着的旧台词永远不会冒出来 ✓
	if false:
		DirAccess.remove_absolute(NUDGE_FILE)
	if not KEEPALIVE_ENABLED:
		PetLog.log("喊一声", "回到前台：闹钟已撤、没喊完的留话已清 ✓")
		return
	# ② 前台服务 + 静音音频（实测那半 ✓）
	if _keepalive_audio != null and _keepalive_audio.playing:
		_keepalive_audio.stop()
	if OS.get_name() == "Android":
		var cls2 = JavaClassWrapper.wrap("com.godot.game.PetBridge")
		if cls2 != null:
			cls2.stopKeepAlive()
			var ex2 = JavaClassWrapper.get_exception()
			if ex2 != null:
				PetLog.warn("保活", "停服务时抛异常：%s" % str(ex2))
	PetLog.log("保活", "回到前台：静音音频已停 ｜ 前台服务已停 ✓")

## 写台词文件（`user://keepalive_lines.txt` ✓ —— Java 那边读的就是同一个文件 ✓）。
## 阶段 9b 收尾（2026-10-11）：**喊声和提醒混在一份里** ✓ ——
## 前台服务那四格 `postDelayed` 到点各消耗一行，所以：
##   ① 行序必须等于到点时间序 ✓（谁先到点谁先被消耗 ✓，乱序她就说错话 ✗）
##   ② 只写前四行 ✓（多出来的写了她也没那一格去喊 ✓，放下次退后台 ✓）
## 返回四格延时（秒，0 = 空着 ✓）—— 调用方原样传给 PetBridge.startKeepAlive ✓
## ⚠️ 生着闷气、或者她本来就不主动说话 → **她的闲聊一句都不留** ✓（那时候不想搭理你 ✓）；
##    但**提醒事项照留** ✓ —— 那是你拜托她的事，闹脾气、关开关都照样办 ✓
func _write_nudge_lines() -> Array:
	var now := Time.get_unix_time_from_system()
	# 到点事件表：{"delay": 还有几秒, "line": 到点说那句, "rid": 提醒 id（闲聊 = -1 ✓）}
	var events: Array = []
	if self_talk_enabled and not _mood.is_muted():
		# ⚠️ 用**无类型**的 Array 接 duplicate() ✗ —— 今天在别处栽过：
		# `Array[String]` 上接 `.duplicate()` 在某些版本会报"类型对不上"的运行时错 ✓
		var pool: Array = LINES_NUDGE.duplicate()
		pool.shuffle()
		for i in NUDGE_AFTER_SEC.size():
			events.append({"delay": float(NUDGE_AFTER_SEC[i]), "line": String(pool[i]), "rid": -1})
	# 提醒：还没说、且在 REMIND_BG_WINDOW 内要到点的 ✓（模块里已按到点排好 ✓）
	for it in _remind.due_within(REMIND_BG_WINDOW, now):
		events.append({
			"delay": float(it.due) - now, "line": _remind.local_line(it), "rid": int(it.id)})
	events.sort_custom(func(a, b): return float(a["delay"]) < float(b["delay"]))
	while events.size() > 4:
		events.pop_back()          # 只留最早的四格 ✓（晚着的等她下次退后台 ✓）
	var f := FileAccess.open(NUDGE_FILE, FileAccess.WRITE)
	if f == null:
		PetLog.warn("喊一声", "台词文件写不进去 ✗（%s）" % NUDGE_FILE)
		# ⚠️ 写失败 = 后台一句都喊不出来 ✓ → **别记排程名单** ✓
		#（不然回前台时会把没喊过的当成喊过了 ✗）
		_remind.mark_scheduled([])
		return [0.0, 0.0, 0.0, 0.0]
	var n_nudge := 0
	var n_remind := 0
	var sched: Array = []
	var delays := [0.0, 0.0, 0.0, 0.0]
	for i in events.size():
		var ev: Dictionary = events[i]
		f.store_line(String(ev["line"]))
		delays[i] = float(ev["delay"])
		if int(ev["rid"]) > 0:
			n_remind += 1
			sched.append(int(ev["rid"]))
		else:
			n_nudge += 1
	f.close()
	# 排程名单（回前台对账用 ✓）：这次真写进去、有格子的那几条提醒 ✓
	_remind.mark_scheduled(sched)
	PetLog.log("喊一声", "留了 %d 句（喊声 %d + 提醒 %d）%s" % [
		n_nudge + n_remind, n_nudge, n_remind,
		"" if n_nudge + n_remind > 0 else "（她现在不想说话 ✓）"])
	return delays

## 把悬浮窗里聊过的那几句**并进正式聊天记录** ✓（Java 只会一行行追加 ✓，格式归这边管 ✓）
## ⚠️ 并完就把文件**删掉** ✗ —— 不删的话每次回前台都会重复并一遍 ✓
func _import_overlay_chat() -> void:
	if not FileAccess.file_exists(OVERLAY_CHAT_FILE):
		return
	var f := FileAccess.open(OVERLAY_CHAT_FILE, FileAccess.READ)
	if f == null:
		return
	var n := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		# 行格式：`谁：话`（Java 固定这么写 ✓）；**只按第一个冒号切** ✗
		# （她自己的话里会有冒号 ✓，用 split 会把后半句切走 ✓）
		var i := line.find("：")
		if i <= 0:
			_chatlog.append("她", line)
			n += 1
			continue
		var who := line.substr(0, i)
		var text := line.substr(i + 1)
		_chatlog.append("我" if who == "主人" else "她", text)
		n += 1
	f.close()
	DirAccess.remove_absolute(OVERLAY_CHAT_FILE)
	PetLog.log("悬浮球", "悬浮窗里聊的 %d 句已并进聊天记录 ✓" % n)

## 把"她是谁 + 最近聊过什么 + 现在几点"写成一份快照 ✓（悬浮窗里打字聊天用 ✓）
## 写不进去也不算错 ✓（那就只剩个没背景的模型在答话 ✓，功能还在 ✓）
func _write_overlay_prompt() -> void:
	# ⚠️ 人设从**记忆模块现成的那个口子**拿 ✗（真机踩到两次）：
	#    `chat_system_prompt` 这个字段在手机上是空的 ✓（快照写出来"0 字" ✗ ——
	#    悬浮窗那头的她就成了个没个性的普通模型 ✗）；
	#    `context_for()` 才是"她是谁 + 记忆 + 现在"真正拼出来的地方 ✓（聊天那条也在用它 ✓）
	var persona := ""
	if _memory_host != null:
		persona = String(_memory_host.context_for(""))
	if persona.strip_edges() == "":
		persona = String(chat_system_prompt)      # 兜底 ✓（哪天真变了还有个老的 ✓）
	var f := FileAccess.open(OVERLAY_PROMPT_FILE, FileAccess.WRITE)
	if f == null:
		PetLog.warn("悬浮球", "人设快照写不进去 ✗（%s）" % OVERLAY_PROMPT_FILE)
		return
	f.store_string(chat_system_prompt)
	f.store_line("")
	f.store_line("【现在】%s" % Time.get_datetime_string_from_system(false, true))
	f.store_line("【你和主人最近聊的】（越靠下越近）")
	for line in _chat_history.slice(maxi(0, _chat_history.size() - 12)):
		f.store_line(String(line))
	f.close()
	PetLog.log("悬浮球", "人设快照已写（%d 字 ✓）→ %s" % [
		persona.length(), OVERLAY_PROMPT_FILE])

## 排两个"喊一声"的 Job ✓
## ⚠️ 走的是 **JobScheduler** 不是 AlarmManager ✗ —— 真机实测：应用退后台会被 app freezer 冻住 ✓，
## 而**被冻结的应用它的闹钟不会被投递** ✗（`dumpsys alarm` 里 Reason=frozen ✓）
## ⚠️ 但**别以为换 Job 就万事大吉** ✗：实测 Job 也一样被押着（`Required: TIMING_DELAY` ✓）——
##    见头部阶段 9b 那段的完整记录 ✓。真正解得开的是「电池不受限制」白名单 ✓（还没验成 ✗）
func _schedule_nudges() -> void:
	if OS.get_name() != "Android":
		return
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		PetLog.warn("喊一声", "wrap 不出 PetBridge ✗，闹钟排不了")
		return
	for i in NUDGE_AFTER_SEC.size():
		cls.scheduleNudge(int(NUDGE_AFTER_SEC[i] * 1000.0), i)     # 两个 Job id 各占一个 ✓
	var ex = JavaClassWrapper.get_exception()      # 官方要求：调完必查 ✓
	if ex != null:
		PetLog.err("喊一声", "安排闹钟时抛异常：%s" % str(ex))
		return
	PetLog.log("喊一声", "闹钟已排：%.0f / %.0f 分钟后各一声 ✓" % [
		NUDGE_AFTER_SEC[0] / 60.0, NUDGE_AFTER_SEC[1] / 60.0])

# ------------------------------------------------------------------ 阶段 8（2026-10-09）：她记得你走开过

## 走开多久才值得提一句（秒）。短了就成了"你切一下 App 她就念叨" ✗
const AWAY_MIN_SEC := 180.0
## "你回来了"那句走模型时用的提示词（和 PROMPT_TOUCH 一个路子：给她事实，口气她自己拿捏 ✓）
const PROMPT_BACK := "（主人刚把手机放在一边走开了 %d 分钟，现在又拿起手机回来了。" \
	+ "用你自己的口气跟他说一句，顺口提一下这段时间 —— 一两句就好，别写成汇报）"

## 退到后台那一刻的**墙钟秒**（-1 = 现在没在后台 ✓）。
## ⚠️ 这里**不用 `Time.get_ticks_msec`**：那是 `CLOCK_MONOTONIC`，**熄屏挂起那段它不走** ✗ ——
## 用户锁屏放两小时再回来，量出来的会是"才几分钟" ✓。墙钟才是"他走了多久" ✓；
## 代价是改系统时间会让它跳 ✗，所以下面有一道范围检查兜着 ✓
var _away_since_unix: float = -1.0

## 回到前台时她"发现"你走开了一会儿 ✓
##
## **为什么要这条**（2026-10-09 真机实测）：手机上退到后台，主循环就被系统暂停 ✓ ——
## 实测那 150 秒里，「每 1 分钟看一眼」一次都没触发 ✗，她一句本地台词也没出 ✗。
## 也就是说：对她而言那段时间是**空白** ✗ —— 心情按墙钟在衰减 ✓、记忆里却什么都没有 ✓，
## 回来时时间凭空跳一大段 ✓。
##
## ⚠️ 这条**不是"保活"** ✗ —— 要她在后台真活着，得上前台服务 + 常驻通知，还会更费电 ✓
## （那是另一条路，见头部计划表）；这里只做一件便宜的事：**承认那段空白存在** ✓，
## 让回来的那一刻接得上 ✓
##
## 说什么按她自己的状态来 ✓：正忙着 / 气泡还在 / 面板开着 / 生着闷气 → 一声不吭 ✓；
## 连不上后端 → 直接一句本地台词 ✓（别让"欢迎回来"反过来依赖联网 ✗）
func _note_return() -> void:
	# 阶段⑤（2026-10-11）：回前台刷一下桌面卡片 ✓ —— 句子不变，但"多久以前"该变新 ✓
	# （放在最前面：下面有好几条提前 return ✓，哪条都不该把刷新漏掉 ✓）
	var _wcls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if _wcls != null:
		_wcls.refreshWidget()
		JavaClassWrapper.get_exception()
	# 提醒事项（2026-10-11）：退后台时排进服务那四格的，到点已经喊过了 ✓ →
	# 只把"当时真排上的"划掉 ✓（没排上的回来由 _remind_tick 补喊 ✓ ——
	# 她答应过的事不能悄没声地没了 ✗）。名单在模块里，见 mark_scheduled ✓
	var said := _remind.reconcile(Time.get_unix_time_from_system())
	if said > 0:
		PetLog.log("提醒", "你走开的时候她已经喊了 %d 条 ✓（回来不重复 ✓）" % said)
	var gone := 0.0
	if _away_since_unix >= 0.0:
		gone = Time.get_unix_time_from_system() - _away_since_unix
	_away_since_unix = -1.0
	# 范围检查：负数（系统时间往回调了）或超过一天（明显是时钟跳了）都当成"说不准" ✓
	if gone < 0.0 or gone > 86400.0:
		PetLog.warn("生命周期", "回来的时间差看着不对（%.0f 秒）→ 这次就不提了" % gone)
		return
	if gone < AWAY_MIN_SEC:
		return
	var mins := maxi(1, int(round(gone / 60.0)))
	PetLog.log("生命周期", "你走开了 %.1f 分钟 → 她去接一句" % (gone / 60.0))
	if _chat_streaming or bubble.is_visible() or _ui_panel_open() or _mood.is_muted():
		return
	if _offline() or _ai_busy():
		_say_local("你回来啦。这 %d 分钟我一直站在这儿，数自己呼吸来着。" % mins)
		return
	_last_origin = "proactive"      # 记忆：算"她自己找的话" ✓（和 pet_proactive 同一种 ✓）
	_send_first(PROMPT_BACK % mins, "")

## 情绪落盘 + 记一行。**Android 上不能只等 _exit_tree** —— 用户从"最近任务"里划掉她时
## 进程是直接没的，所以"退到后台"那一刻就得存（PAUSED 一定会来）
func _save_mood(why: String) -> void:
	if _mood == null:
		return
	_mood.save()
	PetLog.log("生命周期", "%s：情绪已落盘（%s）" % [why, _mood.describe_short()])

func _exit_tree() -> void:
	if _mood != null:
		_mood.save()
	PetLog.log("退出", "进程结束")

# ------------------------------------------------------------------ 模块要问的几个问题

func _offline() -> bool:
	return _chat_flow.offline()

func _ai_busy() -> bool:
	return _chat_streaming

## 面板开着时她不该插嘴（pet_proactive.tick 的门禁之一 ✓）。
## 口径照 desktop_pet._ui_panel_open ✓，只是手机上"面板"只有这四个页面：
##   设置页（右上角⚙ ✓）/ 聊天记录页 ✓ / 记忆浏览页 ✓ / 提醒事项页 ✓
##（桌面那几个 AI 面板 / 名字面板 / 工作台手机上都不存在 ✓，别照抄过来 ✓）
func _ui_panel_open() -> bool:
	if _settings_ui != null and _settings_ui.is_open():
		return true
	if _chatlog_ui != null and _chatlog_ui.is_open():
		return true
	if _memview_ui != null and _memview_ui.is_open():
		return true
	if _remind_ui != null and _remind_ui.is_open():
		return true
	return false

func _vision_ready() -> bool:
	# 阶段 5b：从"恒 false"改成真判据 —— 客户端在 + 配了看图模型 ✓
	#（实现和桌面同一份：pet_memory_host.vision_ready ✓）
	return _memory_host != null and _memory_host.vision_ready()

func _peek_screen() -> String:
	# `DisplayServer.screen_get_image()` 在 Android/iOS 上没有实现 → 明确返回空，
	# 让她说"截屏失败了"，而不是拿到一张黑图去编内容
	return ""

## 人设提示词（"她是谁"那一半 + 记忆 —— 实现在 pet_memory_host）
func _refresh_persona(user_text: String = "") -> void:
	_memory_host.refresh_persona(user_text)

## 她自己先开口那条（找话题 / 生闷气 / 被摸烦了都会从这儿发）。
## 照 desktop_pet 的做法：请求里**顺带**让她把"主人可能接着说什么"也写出来
func _send_first(prompt: String, image: String = "") -> bool:
	_reply_opts_mode = true
	_reply_raw = ""
	_stream_shown = ""
	var ok := false
	if image != "" and _vision != null:
		ok = _vision.send(prompt + PROMPT_OPTIONS_TAIL, image)
	elif _chat != null:
		ok = _chat.send(prompt + PROMPT_OPTIONS_TAIL)
	if not ok:
		_reply_opts_mode = false     # 没发出去就别留这个标记，否则下一次回复会被误拆
	return ok

## 记忆收尾（实现在 pet_memory_host；按"这轮是谁引出来的"决定怎么记）
## ⚠️ 阶段⑤的小组件钩子**不在这一处** ✗：模型整句回复走的是
## `pet_chat_flow.on_replied → _say()` ✓（那边已经写了卡片 ✓）—— 两边都写
## 同一句就白刷一次屏 ✓
func _note_reply(text: String, given: Array = []) -> void:
	_memory_host.note_reply(text, given)

## 提示词里塞原话就行，别把一整篇长文丢进去（和桌面同一个实现）
func _clip(s: String, n: int = 0) -> String:
	var t := s.strip_edges()
	if n <= 0:
		return t
	return t.substr(0, n) if t.length() > n else t

## 给她"编候选"那条喂的上下文：最近几轮对话，**去掉她刚说的那句**
## （提示词里已经单独给了她那句话，重复一次只会让模型更糊）
func _quick_context(reply: String = "") -> String:
	var tail: Array[String] = []
	var skip := "她：" + reply.strip_edges()
	var n := _chat_history.size()
	for i in range(maxi(0, n - 6), n):
		var line := _chat_history[i]
		if i == n - 1 and line == skip:
			continue
		tail.append(line)
	return "\n".join(tail)

# ------------------------------------------------------------------ 每帧另外三条（桌面版的名字，手机版按需实现）
func _check_self_talk(delta: float) -> void:
	# 2026-10-09 接上 ✓：计时 / 四档频率 / 门禁 / 真开口整块在 pet_proactive.gd
	_proactive.tick(delta)

# ------------------------------------------------------------------ 时段问候（2026-10-11）
#
# 早安 / 午饭 / 晚饭 / 深夜催睡 —— 每个时段当天只说一次 ✓。
# 逻辑（时段表、落盘、提示词）在 pet_mobile_greet.gd ✓，这里只负责：
#   ① 倒计时 ② 门禁（和主动说话同一套口径 ✓）③ 真说出口 + 记"今天说过了" ✓
func _greet_tick(delta: float) -> void:
	if not _greet_pending:
		return
	_greet_check_in -= delta
	if _greet_check_in > 0.0:
		return
	_greet_try()

func _greet_try() -> void:
	# 她本来就不主动说话 → 这句招呼也不该说（用户的开关大过日程 ✓）
	if not self_talk_enabled or not _proactive_on:
		_greet_pending = false
		return
	var now := Time.get_datetime_dict_from_system()
	var slot: String = _greet.due(now)
	if slot == "":
		# 要么今天说过了，要么时段已经过了（用户聊了半小时 ✓）—— 都不用再试 ✓
		_greet_pending = false
		return
	if not _she_can_speak_now():
		_greet_check_in = DAILY_RETRY_IN
		return
	var ok := _say_daily(_greet.prompt_for(slot), _greet.local_line(slot))
	_greet.mark(slot, now)
	_greet.save()
	_greet_pending = false
	PetLog.log("时段问候", "说了一句（%s，%s）" % [slot, "模型 ✓" if ok else "本地兜底 ✓"])

# ------------------------------------------------------------------ 纪念日（2026-10-11）
#
# 周年 / 认识满 N 天 —— 一年就几次，当天只说一次 ✓。
# 逻辑（相遇日、天数、提示词）在 pet_mobile_anniv.gd ✓
func _anniv_tick(delta: float) -> void:
	if not _anniv_pending:
		return
	_anniv_check_in -= delta
	if _anniv_check_in > 0.0:
		return
	_anniv_try()

func _anniv_try() -> void:
	if not self_talk_enabled or not _proactive_on:
		_anniv_pending = false
		return
	var now := Time.get_datetime_dict_from_system()
	var info: Dictionary = _anniv.due(now)
	if info.is_empty():
		_anniv_pending = false
		return
	if not _she_can_speak_now():
		_anniv_check_in = DAILY_RETRY_IN
		return
	var ok := _say_daily(_anniv.prompt_for(info), _anniv.local_line(info))
	_anniv.mark(info)
	_anniv.save()
	_anniv_pending = false
	PetLog.log("纪念日", "庆祝了一句（第 %d 天，%s）" % [
		int(info.get("days", 0)), "模型 ✓" if ok else "本地兜底 ✓"])

# ------------------------------------------------------------------ 一天一次那两句共用的两件小工具

## 她现在"方便接一句话"吗（主动说话/问候/纪念日/提醒共用的一套门禁 ✓）。
## 口径和 pet_proactive.tick 里那六道一致 ✓ —— 正忙着 / 在等摄像头 / 气泡还没散 /
## 面板开着 / 生闷气 → 都算不方便 ✓
func _she_can_speak_now() -> bool:
	if _mood.is_muted() or _ai_busy() or _camera_busy \
			or bubble.is_visible() or _ui_panel_open():
		return false
	return true

## "日程类"的一句话（问候/纪念日 ✓）：连得上就她自己拿捏，连不上就本地台词 ✓
## （和「欢迎回来」同一条规矩：离线不该让日程反过来依赖联网 ✗）。
## 返回 true = 走的是模型 ✓（调用方拿它记日志 ✓）
func _say_daily(prompt: String, local: String) -> bool:
	if _offline():
		_say_local(local)
		return false
	_last_origin = "proactive"      # 记忆：算"她自己找的话" ✓
	if not _send_first(prompt, ""):
		_say_local(local)
		return false
	return true

# ------------------------------------------------------------------ 电量/充电关心（2026-10-11）
#
# 手机桌宠独占的几句 ✓："你手机快没电了" / "在充电呀" ✓。
# 多久看一次、什么阈值、回滞，全在 pet_mobile_battery.gd ✓；这里只管说 ✓。
## ⚠️ 没说出口就不 mark ✓（被门禁挡了下次轮询自然再试 ✓ —— 低电量/充电都会持续一会儿 ✓）
func _battery_tick(delta: float) -> void:
	var ev: Dictionary = _battery.tick(delta)
	if ev.is_empty():
		return
	var name: String = String(ev.get("ev", ""))
	var pct := int(ev.get("pct", -1))
	# 她本来就不主动说话 → 电量关心也不说（用户的开关大过这些 ✓）
	if not self_talk_enabled or not _proactive_on:
		return
	if not _she_can_speak_now():
		return          # 这次不标记 → 下一轮轮询还会问 ✓
	var ok := false
	if name == PetMobileBattery.EV_LOW:
		var local := LINES_BATTERY_LOW[_rng.randi_range(0, LINES_BATTERY_LOW.size() - 1)]
		# ⚠️ 只在真带 %d 时才格式化：探针实测 Godot 4.6 下"无占位符串 % 值"
		# 会打 String formatting error（返回值碰巧是原串，但每轮到一句
		# 就往日志里喷一条 ✗ —— 不猜，见 tools/probe_daily.gd D 段）
		if pct >= 0 and local.contains("%d"):
			local = local % pct
		ok = _say_daily(PROMPT_BATTERY_LOW % maxi(pct, 0), local)
	elif name == PetMobileBattery.EV_CHARGING:
		ok = _say_daily(PROMPT_BATTERY_CHARGING,
			LINES_BATTERY_CHARGING[_rng.randi_range(0, LINES_BATTERY_CHARGING.size() - 1)])
	if ok or _offline():
		_battery.mark(name)     # 真说了（或离线也本地说了 ✓）才记 ✓
	PetLog.log("电量关心", "%s（%d%%，%s）" % [name, pct, "模型 ✓" if ok else "本地/没说 ✓"])

# ------------------------------------------------------------------ 提醒事项（2026-10-11）
#
# 她的小本本 ✓：主人打字"提醒我十分钟后开会" → `_remind.parse` 当场记下（_submit_chat ✓），
# 到点她喊出来 ✓。和问候/纪念日/电量那些"她自己想起来"的分工：
#   那些看她主动说话的开关 ✓；**这条不看** ✓ —— 你拜托她的事，开关管不着 ✓
func _remind_tick(delta: float) -> void:
	if _remind_check_in > 0.0:
		_remind_check_in -= delta
		return
	_remind_check_in = REMIND_POLL_IN
	var due: Array = _remind.due_open(Time.get_unix_time_from_system())
	if due.is_empty():
		return
	var it: Variant = due[0]          # 一次只说一条 ✓（连着喊两条像连珠炮 ✗）
	if not _she_can_speak_now():
		return          # 没说就不标 ✓（下一轮再试 ✓）
	var ok := _say_daily(_remind.prompt_for(it), _remind.local_line(it))
	_remind.mark_done(int(it.id))
	PetLog.log("提醒", "到点喊了一条（%s，%s）" % [
		String(it.text), "模型 ✓" if ok else "本地兜底 ✓"])

func _check_peek(_delta: float) -> void:
	pass        # 手机版没有截屏这条（见头部说明）

func _check_camera(delta: float) -> void:
	# 阶段 5b 接上 ✓：倒计时 / 假死 / 忙 / 面板开着 / 正在流 —— 那些门禁全在 pet_peek.check_camera ✓
	_peek.check_camera(delta)

# ------------------------------------------------------------------ 看摄像头（阶段 5b）

## 看图那条的客户端 + 「让她看摄像头」这个开关：**按需建** ✓
##
## 桌面是开局无条件建、靠 vision_model 是否为空来开关 ✓；手机上一个没配过的用户
## 白建一条客户端没意义（还多一次探活请求 ✗），所以这里晚一步、由它自己管 ✓。
## ⚠️ 开关跟着**模型字符串**走：手机上看图模型只有摄像头这一个用途 ✓（截屏那条没有 ✗）
func _apply_vision() -> void:
	_camera_on = vision_model.strip_edges() != ""
	# 间隔被改过就**立刻按新的重数**（阶段 7）：不重数就得等旧那一轮走完，
	# 用户会以为"改了没用" ✗；反过来"没改就不动" ✓ —— 存一次密钥不该把她的看一眼推后 ✓
	if not is_equal_approx(_camera_every_applied, camera_every_min):
		_camera_every_applied = camera_every_min
		_camera_timer = maxf(1.0, camera_every_min) * 60.0
	if _camera_on and _camera_timer <= 0.0:
		_camera_timer = maxf(1.0, camera_every_min) * 60.0
	# ⚠️ **"关掉"这一段必须在"已经建过"之前**（2026-10-09 真机验出来的顺序错 ✗）：
	# 原先它写在 `if _vision != null: … return` **后面** ✓，于是只要建过一次就永远从那句
	# return 走掉 → 这一段**一辈子执行不到** ✗（日志里该有的"停掉"那行当时就是不出现 ✓，
	# 正是它把这个顺序错暴露出来的 ✓）。功能上"她不再自己看一眼"是靠 _camera_on 拦住的 ✓，
	# 但那行提示和她这条客户端的收尾都得走到这儿 ✓
	if not _camera_on:
		if _vision != null:
			PetLog.log("摄像头", "看图模型清空了 → 摄像头那条停掉（她不再自己看一眼 ✓）")
		return
	if _vision != null:
		# 已经建过就只灌新配置（历史上下文留着 —— 和桌面 _apply_chat_config 一个道理 ✓）
		_vision.configure(chat_url, _memory_host.vision_key(), vision_model)
		_request_camera_permission()
		return
	_vision = PetChat.new()
	_vision.configure(chat_url, _memory_host.vision_key(), vision_model)
	_vision.system_prompt = chat_system_prompt
	_vision.context_provider = func(query: String) -> String:
		return _memory_host.context_for(query)
	# 四个出口接到**同一份** pet_chat_flow（共用气泡 / 记忆 / 候选 ✓）：
	# 只有 stream_ended 走手机自己那个壳 —— 它要多解一把"等摄像头"的锁 ✓
	_vision.token.connect(_chat_flow.on_token)
	_vision.replied.connect(_chat_flow.on_replied)
	_vision.failed.connect(_chat_flow.on_failed)
	_vision.stream_ended.connect(_on_vision_stream_ended)
	_vision.probe_now()
	PetLog.log("摄像头", "看图那条起来了 ｜ 模型 %s ｜ key %s ｜ 每 %.0f 分钟自己看一眼" % [
		vision_model, "有" if _memory_host.vision_key() != "" else "没有", camera_every_min])
	_request_camera_permission()

## 视觉那条收尾：照桌面 `_on_vision_stream_ended` ✓ ——
## 清掉通用标记 + 解开"等摄像头"那把锁（camera_look 自己也会解，这是第二道保险 ✓）
func _on_vision_stream_ended() -> void:
	_camera_busy = false
	_chat_flow.on_stream_ended()

## Android 6+ 的相机权限要在**运行时**再要一次（export_presets 里那条只是"声明" ✓）。
## 什么时候要：只在她真的要开摄像头时（看图模型刚填上 ✓）——
## 一装上就弹权限框太像流氓软件 ✗；没配看图模型的用户根本看不到这个框 ✓
func _request_camera_permission() -> void:
	if OS.get_name() != "Android":
		return
	const PERM := "android.permission.CAMERA"
	if OS.get_granted_permissions().has(PERM):
		return
	OS.request_permission(PERM)
	if OS.is_debug_build():
		print("[PetDeek] 申请相机权限（Android 运行时那条，系统会弹框 ✓）")

# ------------------------------------------------------------------ 一键导出日志（阶段 6，2026-10-09）

## 把日志 + 系统信息收成一份 zip，放进手机公共的「下载」里 ✓
##
## 和桌面**同一条路**（共用 pet_log.gd 的 export_logs ✓）：导出前每一行都过一遍
## `_redact()` 抹掉密钥 ✓，所以这份包可以直接发给别人 ✓。
## 差别只在落点：
##   桌面 → `OS.get_system_dir(DESKTOP)` ✓；
##   手机 → 那个取不到 → export_logs 自己会退到 `user://` ✓（这段判断是共用的 ✓），
##          再由 PetBridge 挪进「下载」✓ —— 沙箱里的文件用户拿不到 ✗，
##          而「下载」是他自己就能转发出去的地方 ✓
func _export_logs() -> void:
	var out := PetLog.export_logs(_log_info(), [chat_access_key])
	if out == "":
		PetLog.err("日志", "导出失败：连 user:// 都写不进去")
		_say("导出没成功…")
		return
	PetLog.log("日志", "导出到 %s" % out)
	var placed := ""
	if OS.get_name() == "Android":
		var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
		if cls != null:
			placed = String(cls.saveToDownloads(out, out.get_file()))
			var ex = JavaClassWrapper.get_exception()      # 官方要求：调完必查 ✓
			if ex != null:
				PetLog.err("日志", "放进「下载」时抛异常：%s" % str(ex))
				placed = ""
	if placed != "":
		_say("日志收好啦，在手机的「下载」里～")
	else:
		# 如实说 ✗ —— 别让用户以为"导出成功"就能随手拿到 ✓
		_say("日志收好啦（在应用自己的目录里）")
		PetLog.warn("日志", "没放进「下载」；只能用 adb 拉：%s" % out)

## 导出时列进「她那边的设置」那一节（照桌面 `_log_info` 的口径 ✓）。
## ⚠️ 写进这里的东西**是要发给别人的** ✓：只放"有没有配密钥"，
## **永远不放密钥本身** ✓（pet_log 那边还会再隐去一遍，两道 ✓）
func _log_info() -> Dictionary:
	return {
		"平台": "%s %s" % [OS.get_name(), OS.get_version()],
		"AI 后端": chat_url,
		"对话模型": chat_model,
		"看图模型": "关" if vision_model.strip_edges() == "" else vision_model,
		"密钥": "已配置" if chat_access_key.strip_edges() != "" else "未配置",
		"看摄像头": "开" if _camera_on else "关",
		"偷看屏幕": "关（移动端没有截屏那条 ✓）",
		"触感": "开" if haptic_enabled else "关",
	}
