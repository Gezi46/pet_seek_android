# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 手机端的**设置页**（阶段 3 第二部分，2026-10-08）：三个字段 + 一个开关 + 存。
##
## 为什么运行时建、不写进 .tscn：和桌面的聊天面板同一个理由 —— 场景文件里塞这些
## 只会让 .tscn 越来越难读，而这一页本来就只有点开时才需要存在。
##
## 谁打开它：`pet_mobile_ui` 右上角那个「⚙」（手机上没有右键菜单，得给个门）。
## 它自己只认两样东西：宿主身上的 `_settings`（存取实现在 pet_mobile_settings.gd）、
## 以及"存完让她说一句"的 `_say_local`。
##
## 对宿主的接口面：
##   host._settings        pet_mobile_settings 的实例（读写字段 + save_settings）
##   host._cjk_font        中文字体
##   host._say_local()     存完给个反馈（走她自己的对话框，不另造提示框）
##   host.get_node_or_null("UI/Anchor")

## 日志（存设置时记一行）。每个用到的文件都得自己 preload —— 常量不跨文件继承
const PetLog := preload("res://scripts/sys/pet_log.gd")
## 档位名 / 位置名那两张表在设置脚本里（**单一来源** ✓，别在这儿再抄一份 ✗）
const Settings := preload("res://scripts/mobile/pet_mobile_settings.gd")

## 面板宽度（设计坐标）：留出左右拇指区的边距
const PANEL_W := 400.0
const ROW_H := 46.0
const FONT := 16.0
const TITLE_FONT := 20.0

var _host = null
var _root: Control = null          # 遮罩（整屏，挡住背后的 3D 点击）
var _panel: VBoxContainer = null
var _url: LineEdit = null
var _model: LineEdit = null
var _key: LineEdit = null
## ⚠️ "空密钥**连按两次**才真清"的那一步（2026-10-12："换模型 apikey 丢失" ✓）。
## 手机上这一栏的提示语就是"留空 = 只当本地桌宠" ✓，所以留空**是合法意图** ✓ ——
## 可它和"手滑清掉了"长得一模一样 ✗，而 `_write_secret("")` 会直接把密钥文件删掉 ✓，
## 于是"改完模型再改回来，key 就没了" ✓。规矩（和桌面面板一致 ✓）：
## 空着保存**第一次** = 先留着 + 说明白 ✓；连着**第二次** = 才是真不要了 ✓
var _key_clear_pending := false
var _vision: LineEdit = null
var _haptic: CheckButton = null
var _overlay: CheckButton = null        # 阶段 10：悬浮球 ✓
var _msg: Label = null
# 阶段 7（2026-10-09）：她自己开口 / 她怎么看 —— 这四项以前在宿主里是**写死的** ✓
var _scroll: ScrollContainer = null
var _proactive: CheckButton = null
var _rate: Button = null            # "点一下换一档"，当前档在它的 metadata("idx") 里 ✓
var _cam_pos: Button = null
var _cam_every: LineEdit = null
# 阶段 13（2026-10-10）：免授权截屏（无障碍）的**状态**那一行 ✓（开关在系统里，不在 cfg ✓）
var _a11y_state: Label = null
# 阶段 9b 收尾（2026-10-11）：电池优化白名单的状态那一行 ✓（同样是"开关在系统里" ✓）
var _battery_state: Label = null

func setup(host) -> void:
	_host = host

func is_open() -> bool:
	return _root != null and _root.visible

func toggle() -> void:
	if is_open():
		close()
	else:
		open()

## 打开：第一次点开时才把这一页建出来（之后只是显示/隐藏）
func open() -> void:
	if _root == null:
		_build()
	_sync_from_settings()
	if is_open():
		return
	_root.visible = true
	# 软键盘是 LineEdit 聚焦时系统自己弹的；这里不主动弹，免得一打开就挡住半屏
	_msg.text = ""

func close() -> void:
	if _root != null:
		_root.visible = false

# ------------------------------------------------------------------ 建这一页

func _build() -> void:
	var anchor := _host.get_node_or_null("UI/Anchor") as Control
	if anchor == null:
		return
	# 遮罩：整屏、半透明黑。`MOUSE_FILTER_STOP` 是关键 —— 挡住背后的"点她/收对话框"
	_root = Control.new()
	_root.name = "SettingsPage"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	anchor.add_child(_root)

	var scrim := ColorRect.new()
	# 0.72 → 0.90（阶段 7）：这一页越来越长之后，她那块 3D 会从半透的遮罩下透上来 ✓，
	# 正好压在中间几行字上（真机截图里看得很清楚 ✗）→ 压深一点，字才看得住 ✓
	scrim.color = Color(0.03, 0.05, 0.09, 0.90)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(scrim)

	# ⚠️ **必须能滚**（阶段 7 加的）：又添了四行之后，这一页在 450×1000 的设计分辨率下
	# 会**超出屏幕下沿** ✗ —— 底下那排「取消 / 保存」就点不着了 ✓。
	# 用 ScrollContainer 兜住整列；横向关掉（内容宽度本来就固定 ✓）、
	# follow_focus 打开（键盘弹起来时别把正在填的输入框顶到看不见的地方 ✓）
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2((450.0 - PANEL_W) * 0.5, 96.0)
	# 高度扣掉底部那条钉住的按钮栏（918 ✓）—— 别让最后一行的字压在按钮底下 ✓
	_scroll.custom_minimum_size = Vector2(PANEL_W, 810.0)
	_scroll.size = Vector2(PANEL_W, 810.0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_root.add_child(_scroll)

	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 8)
	_panel.custom_minimum_size = Vector2(PANEL_W, 0.0)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_panel)

	_panel.add_child(_title("设置"))
	_panel.add_child(_hint("手机上她连的是你自己的 AI 后端。密钥只存在这台手机里，不会进设置文件。"))

	# ── 分区（2026-10-09 用户提的："堆在一起不好滑着找" ✓）────────────
	_section("AI 后端")
	_url = _row("AI 后端地址", "https://api.deepseek.com")
	_model = _row("模型", "deepseek-flash")
	_key = _row("密钥（sk- 开头）", "留空 = 只当本地桌宠")
	_key.secret = true

	_section("摄像头（她能看见什么）")
	# 阶段 5b：看图那条。手机上它只有**摄像头**这一个用途（截屏移动端没有 ✓）
	_vision = _row("看图模型（留空 = 不看摄像头）", "填上她就时不时看一眼摄像头")
	_panel.add_child(_hint("手机上她只能看摄像头（截屏那条移动端没有）。" \
		+ "填了模型就开、留空就关，密钥复用上面那把。"))
	# 阶段 7：她怎么看
	_cam_pos = _cycle("用哪个摄像头", Settings.POS_NAMES, 0)
	_cam_every = _row("她多久看一眼（分钟，1~60）", "10")
	_panel.add_child(_hint("她「看一眼」看的是前置（对着你的那张脸）✓ —— " \
		+ "后置对着桌子，除非你故意要她看别的 ✓"))
	_panel.add_child(_button("现在看一眼摄像头", _look_now))

	_section("截屏（她看一眼你的屏幕）")
	# 阶段 13（2026-10-10，用户报的："每次截图都要申请权限、不够方便" ✓）
	# ⚠️ 这一行**不是存在 cfg 里的开关** ✗ —— 真开关在系统「设置 → 无障碍」里 ✓，
	#    我们只能拉起那个页面、再由用户自己点 ✓（所以这里只显示状态 + 一个"去开"按钮 ✓）
	_panel.add_child(_button("去开「免授权截图」", _open_a11y))
	_a11y_state = _hint("")
	_panel.add_child(_a11y_state)
	_panel.add_child(_hint("开了之后，双击她截屏**不再每次都弹系统授权框**（安卓 11 及以上）。" \
		+ "没开也照样能截，只是每次都要你当面点一下「允许」。"))

	_section("她自己")
	# 阶段 7：她自己开口
	_proactive = _check("主动说话（她时不时自己找你聊）")
	_rate = _cycle("多久没人理她就开口", Settings.RATE_NAMES, 1)
	_haptic = _check("摸她有震动反馈")
	# 阶段 10（2026-10-09）：悬浮球 —— 她在别的 App 上浮着，说话冒气泡 ✓
	_overlay = _check("悬浮球（在别的 App 上也能看到她）")
	_panel.add_child(_hint("勾上之后会拉起系统的「显示在其他应用上层」授权页 ✓ —— " \
		+ "允许了才会浮出来（这是安卓的要求，绕不过去 ✓）"))
	# 2026-10-11（第二梯队⑥）：把她记住的事摊开给人看，可逐条「忘掉」✓
	_panel.add_child(_button("她记得的事…", _open_memview))
	_panel.add_child(_hint("翻开看看她记住了你什么（名字、喜好、聊过的事）。" \
		+ "不想要的条目可以当她的面「忘掉」—— 忘掉就真忘了，救不回来 ✓"))
	# 2026-10-11（第二梯队⑧）：她的小本本 ✓（**添加不在这儿** ✗ ——
	# 跟她本人说"提醒我十分钟后开会"她就记下了 ✓，这一页只管翻和删 ✓）
	_panel.add_child(_button("提醒事项…", _open_remind))
	_panel.add_child(_hint("跟她说「提醒我十分钟后开会」她就记下了 ✓ 到点她喊你 ✓" \
		+ "（你拜托她的事，跟她自己开口那个开关没关系 —— 关了她也照样喊 ✓）"))

	_section("工具")
	# 阶段 6（2026-10-09）：手机上没控制台 ✗ —— 出问题时就靠它把现场带出来 ✓
	_panel.add_child(_button("导出日志", _export_logs))
	# 阶段 9b 收尾（2026-10-11）：电池优化白名单 ✓ —— "让她一直在"的第二道保险 ✓
	# ⚠️ 和免授权截屏那一行同一种"开关在系统里"的东西 ✓：这里只显示状态 + 拉起
	#    系统那个对话框 ✓（用户不想给也不影响功能 ✓ —— 前排前台服务已经解了 freezer ✓）
	_panel.add_child(_button("让她一直在（电池白名单）", _open_battery_whitelist))
	_battery_state = _hint("")
	_panel.add_child(_battery_state)
	# 阶段⑤（2026-10-11）：桌面小组件 ✓ —— 只给一句指引，**不放按钮** ✗：
	# 安卓没有"打开小组件选择器"的标准 intent ✗（各桌面自家实现 ✗，硬拉只会
	# 跳到一些不该跳的地方 ✓），长按桌面是唯一可靠入口 ✓（见 PetWidget 类头 ✓）
	_panel.add_child(_hint("想让她常驻桌面：长按桌面空白处 →「小组件 / 添加小工具」"
		+ "→ 找「她的一句话」✓ 她说过的最近一句会留在那儿，点一下卡片就把她叫回来 ✓"))
	# 注："从相册选一张给她"**不在这儿** ✗ —— 2026-10-09 挪到聊天框那个「＋」上了 ✓
	#（设置页是"改配置"的地方，发图是聊天时的动作，放聊天框顺手得多 ✓）

	_msg = _hint("")
	_panel.add_child(_msg)

	# ⚠️ 「取消 / 保存」**钉在屏幕底部**（2026-10-09 用户提的）：这一页现在十来行、
	# 得滑到底才够得着保存 ✗ —— 而"保存"恰恰是每个进来的人唯一一定要点的那个 ✓。
	# 所以它**不进滚动区**，直接挂在遮罩上 ✓（滚动区高度让出来那一段，见上面 _scroll ✓）
	var bar := HBoxContainer.new()
	bar.position = Vector2((450.0 - PANEL_W) * 0.5, 918.0)
	bar.custom_minimum_size = Vector2(PANEL_W, 0.0)
	bar.add_theme_constant_override("separation", 10)
	bar.alignment = BoxContainer.ALIGNMENT_END
	_root.add_child(bar)
	bar.add_child(_button("取消", close))
	bar.add_child(_button("保存", _save))

func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _host._cjk_font)
	l.add_theme_font_size_override("font_size", TITLE_FONT)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	return l

func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W, 0.0)
	l.add_theme_font_override("font", _host._cjk_font)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.75, 0.82, 0.95, 0.8))
	return l

## 设置页的分区小标题（2026-10-09 用户提的："功能堆在一起不好滑着找" ✓）。
## 样式上就做三件事：上面留一段空、字大一号、底下一道细线 —— 手指快速划过时能当路标用 ✓
func _section(text: String) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(PANEL_W, 16.0)
	_panel.add_child(gap)
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _host._cjk_font)
	l.add_theme_font_size_override("font_size", FONT + 3.0)
	l.add_theme_color_override("font_color", Color(0.55, 0.80, 1.0, 0.95))
	_panel.add_child(l)
	var line := ColorRect.new()
	line.color = Color(0.55, 0.80, 1.0, 0.28)
	line.custom_minimum_size = Vector2(PANEL_W, 1.0)
	_panel.add_child(line)

## 一行 = 小标题 + 输入框（高度给足，手指点得着）
func _row(label_text: String, placeholder: String) -> LineEdit:
	_panel.add_child(_hint(label_text))
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(PANEL_W, ROW_H)
	e.add_theme_font_override("font", _host._cjk_font)
	e.add_theme_font_size_override("font_size", FONT)
	e.placeholder_text = placeholder
	_panel.add_child(e)
	return e

## 开关一行（阶段 7）：和 `_row` 一个路子 —— 先小标题、再控件，只是控件换成勾选框 ✓
func _check(text: String) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.add_theme_font_override("font", _host._cjk_font)
	c.add_theme_font_size_override("font_size", FONT)
	c.focus_mode = Control.FOCUS_NONE
	_panel.add_child(c)
	return c

## "点一下换一档"那种按钮（阶段 7）。
##
## 为什么不用 OptionButton ✗：它弹的是系统 PopupMenu，而这一页是我们自己在 CanvasLayer 里画的，
## 弹窗的层级/位置在真机上不好预期 ✗；况且手机上"点一下就换下一档"本来就比弹菜单顺手 ✓。
## 当前档位存在按钮的 `metadata("idx")` 里 ✓ —— `_save` 直接读它，不用再找地方存 ✓
func _cycle(hint_text: String, options: Array, initial: int) -> Button:
	_panel.add_child(_hint(hint_text + "（点一下换一档）"))
	var b := Button.new()
	b.custom_minimum_size = Vector2(PANEL_W, ROW_H)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _host._cjk_font)
	b.add_theme_font_size_override("font_size", FONT)
	b.set_meta("idx", clampi(initial, 0, options.size() - 1))
	b.set_meta("options", options)
	b.pressed.connect(_cycle_next.bind(b))
	_refresh_cycle(b)
	_panel.add_child(b)
	return b

func _cycle_next(b: Button) -> void:
	var opts: Array = b.get_meta("options")
	b.set_meta("idx", (int(b.get_meta("idx")) + 1) % opts.size())
	_refresh_cycle(b)

func _refresh_cycle(b: Button) -> void:
	var opts: Array = b.get_meta("options")
	b.text = "%s ▸" % String(opts[int(b.get_meta("idx"))])

## 「导出日志」（阶段 6）：收成一份 zip 放进手机的「下载」✓
## （实现全在宿主 `_export_logs` ✓ —— 收哪些文件、怎么抹密钥，都是共用的 pet_log.gd 说了算 ✓）
func _export_logs() -> void:
	close()
	PetLog.log("日志", "设置页点了「导出日志」")
	_host._export_logs()

## "现在就看一眼"（桌面是右键菜单里那条 ✓，手机上没菜单 → 收在设置页里 ✓）。
## ⚠️ camera_look() 是协程，这里**故意不 await**（和 pet_peek 的定时那条一样 ✓）：
## 让它自己跑完，期间靠宿主那把 _camera_busy 挡重入 ✓
func _look_now() -> void:
	close()
	PetLog.log("摄像头", "设置页点了「现在看一眼摄像头」")
	if _host._peek != null:
		_host._peek.camera_look()

## 阶段 13：把用户送到系统「设置 → 无障碍」去开「桌宠截屏」✓
## ⚠️ **不 close()** ✗：他从系统设置回来时，这一页还该开着、状态也该更新 ✓
func _open_a11y() -> void:
	PetLog.log("截屏", "设置页点了「去开免授权截图」")
	_host._open_a11y_shot_settings()
	# 立刻刷一次（多半还没开 ✓）；回来后再点开这一页时 _sync_from_settings 会再刷一次 ✓
	_refresh_a11y_state()

## 阶段 13：更新那一行状态字 ✓
func _refresh_a11y_state() -> void:
	if _a11y_state == null:
		return
	if _host._a11y_shot_ready():
		_a11y_state.text = "现在：已开启 ✓（双击她截屏不再弹系统授权框）"
	else:
		_a11y_state.text = "现在：未开启（双击也能截，但每次都会弹一次系统授权框）"

## 「她记得的事…」（2026-10-11，第二梯队⑥）：翻开记忆浏览页 ✓
## ⚠️ 不在这儿 close() ✗ —— 宿主 `toggle_memview()` 自己会关设置页
##（三个全屏面板互斥，"关谁开谁"统一由宿主说，见那三个 toggle_* ✓）
func _open_memview() -> void:
	PetLog.log("记忆", "设置页点了「她记得的事」")
	_host.toggle_memview()

## 「提醒事项…」（2026-10-11，第二梯队⑧）：翻开她的小本本 ✓
## ⚠️ 同 memview：不在这儿 close() ✗ —— 宿主 `toggle_remind()` 自己会关设置页 ✓
func _open_remind() -> void:
	PetLog.log("提醒", "设置页点了「提醒事项」")
	_host.toggle_remind()

## 阶段 9b 收尾（2026-10-11）：拉起系统"忽略电池优化"对话框 ✓
## ⚠️ 同免授权截屏：**不 close()** ✗ —— 那是系统对话框，回来这一页还该开着 ✓
func _open_battery_whitelist() -> void:
	PetLog.log("保活", "设置页点了「电池白名单」")
	_host._open_battery_whitelist()
	_refresh_battery_state()

## 阶段 9b 收尾（2026-10-11）：那一行状态字 ✓（读系统，不是 cfg ✓）
func _refresh_battery_state() -> void:
	if _battery_state == null:
		return
	if _host._battery_whitelist_ready():
		_battery_state.text = "现在：已允许 ✓（系统的省电策略不会再去按她 ✓）"
	else:
		_battery_state.text = "现在：没允许（她也照样跑 ✓ —— 只是省电策略可能顺手把她按一下 ✓）"

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(110.0, ROW_H)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _host._cjk_font)
	b.add_theme_font_size_override("font_size", FONT)
	b.pressed.connect(cb)
	return b

# ------------------------------------------------------------------ 读 / 写

func _sync_from_settings() -> void:
	var s = _host._settings
	if s == null:
		return
	_key_clear_pending = false     # 上一轮那个"要清空"的意图不跨次保留 ✓（和桌面面板同一条规矩 ✓）
	_url.text = String(s.chat_url)
	_model.text = String(s.chat_model)
	_key.text = String(s.chat_access_key)
	_vision.text = String(s.vision_model)
	_haptic.button_pressed = bool(s.haptic)
	_overlay.button_pressed = bool(s.overlay)
	# 阶段 7 那四项 ✓
	_proactive.button_pressed = bool(s.proactive_on)
	_rate.set_meta("idx", clampi(int(s.talk_rate), 0, Settings.RATE_NAMES.size() - 1))
	_refresh_cycle(_rate)
	_cam_every.text = "%.0f" % float(s.camera_every_min)
	_cam_pos.set_meta("idx", clampi(int(s.camera_position), 0, Settings.POS_NAMES.size() - 1))
	_refresh_cycle(_cam_pos)
	_refresh_a11y_state()      # 阶段 13：免授权截屏的开/关状态（读系统，不是 cfg ✓）
	_refresh_battery_state()   # 阶段 9b 收尾：电池白名单的开/关状态（同样读系统 ✓）

## 存：写字段 → 落盘 → **立刻写回宿主**（不然要重启才生效）
func _save() -> void:
	var s = _host._settings
	if s == null:
		return
	s.chat_url = _url.text.strip_edges()
	s.chat_model = _model.text.strip_edges()
	# ⚠️ **空 key ≠ 要删 key** ✗（"换模型 apikey 丢失"这条的规矩 ✓）：
	#   这一栏的提示语就是"留空 = 只当本地桌宠" ✓ —— 留空**是合法意图** ✓，
	#   可它和"手滑清掉了"长得一模一样 ✗，而 `_write_secret("")` 会直接把那个密钥文件
	#   remove 掉 ✓，再也回不来 ✓（真机上就表现成"改完模型 key 就没了" ✓）。
	#   规矩（和桌面面板一致）：空着保存**第一次**先留着 + 说明白 ✓；连着**第二次**才真清 ✓
	var typed_key := _key.text.strip_edges()
	if typed_key == "" and String(s.chat_access_key).strip_edges() != "" and not _key_clear_pending:
		_key_clear_pending = true
		_msg.text = "密钥栏是空的：你原来那把 key 我先留着 ✓ —— 真想清掉，就再按一次「保存」✓"
		return
	# 走到这儿就照栏位写 ✓（要么是"第二次确认" ✓、要么本来就没 key ✓）
	_key_clear_pending = false
	s.chat_access_key = typed_key
	s.vision_model = _vision.text.strip_edges()
	s.haptic = _haptic.button_pressed
	s.overlay = _overlay.button_pressed
	if s.overlay:
		_host._request_overlay_permission()      # 勾上就去要那个授权 ✓（没授权浮不出来 ✓）
	# 阶段 7 ✓（间隔那格：手打进来的也夹一下 ✓；**空着就保持原值** ✓ ——
	# 别把空串当成 0 再夹成 1 分钟 ✗，那会让她突然每 60 秒盯你一眼）
	s.proactive_on = _proactive.button_pressed
	s.talk_rate = int(_rate.get_meta("idx"))
	s.camera_position = int(_cam_pos.get_meta("idx"))
	var every := _cam_every.text.strip_edges()
	if every != "":
		s.camera_every_min = clampf(every.to_float(), 1.0, 60.0)
	s.save_settings()
	s.apply_to(_host)
	_host.on_settings_saved()      # ⚠️ 这一步不能少：不重装客户端就得重启才生效
	PetLog.log("设置", "手机端设置已保存：%s" % s.describe())
	_msg.text = "存好了 ✓"
	close()
	# 反馈走她自己的对话框（手机上不另造提示框，保持一个说话的地方）
	if _host.chat_access_key == "":
		_host._say_local("设置存好啦。不过你还没填密钥，我先只当本地桌宠～")
	else:
		_host._say_local("设置存好啦～")
