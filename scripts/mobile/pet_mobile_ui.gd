# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 手机端的**界面层**（阶段 3，2026-10-08）：galgame 版式的底部对话框 + 手指按得着的按钮。
##
## 为什么单独一个文件：桌面上那套 UI（小气泡 / 右键菜单 / 聊天面板）是照 **330×470 的窗口 +
## 鼠标**写的；手机是 450×800 竖屏 + 手指，位置和字号都得另给一套。
##
## 但"她说了什么"这条线**不分叉** —— 台词还是 pet_touch / pet_mood_ui 给的，
## 这里只负责：怎么摆、多大、什么时候收起来。
##
## 对宿主的接口面（只列真正用到的）：
##   host._bubble               桌面那个 Label，手机上把它当"对话框的文字区"
##   host._cjk_font             中文字体（项目里没配 CJK 字体，见 pet_mobile._build_cjk_font）
##   host.chat_persona_name     名字条上的名字
##   host.get_node_or_null("UI/Anchor")
##   host._soothe_her()         「哄她」按钮点完要哄她（实现在 pet_mood_ui）

## 设计分辨率（和 pet_mobile.DESIGN_SIZE 一致）：这个文件里的数字都按它写，
## 运行时由 content_scale 撑到整屏
const DESIGN := Vector2(450.0, 800.0)
## 底部：对话框高度 + 打字输入行（设计坐标）。
## 2026-10-08 加输入行时把对话框从 152 收到 110 —— 底下要给输入框让位（它必须在屏幕最底，
## 拇指才够得着）。两个加起来 ~180，对话框上沿落在 818（她的脚 769 仍在上面 ✓）
const BOX_H := 110.0
const INPUT_H := 44.0
const GAP := 8.0
const BOX_MARGIN := 12.0
const FONT_SIZE := 19
const NAME_SIZE := 15
## 「哄她」选择框的按钮：手指按得着的高度与字号。
## Material 的建议是触控目标 ≥ 44dp —— 这里是设计坐标 40，换算到这台真机
## （1260 宽 / 设计 450 ≈ 2.8 倍）约等于 112 物理像素，够用
const BTN_H := 40.0
const BTN_FONT := 17
## 触感时长（毫秒）。0 = 关掉
const HAPTIC_MS := 15

## 日志（键盘顶起时记一行，便于在真机上确认那条路走通了）
const PetLog := preload("res://scripts/sys/pet_log.gd")

var _host = null
var _anchor: Control = null
var _name: Label = null
var _hint: Label = null
## 打字输入行（LineEdit + 发送）
var _input_row: HBoxContainer = null
var _input: LineEdit = null
## 软键盘高度（像素）。>0 时底部整体上移这么多
var _kb_lift: float = 0.0

func setup(host) -> void:
	_host = host
	_anchor = host.get_node_or_null("UI/Anchor") as Control
	if _anchor == null or _host._bubble == null:
		return
	_style_bubble()
	_add_parts()
	_build_input()

## 屏幕最底下那行：输入框 + 发送。放最底是拇指够得着的唯一位置
func _build_input() -> void:
	_input_row = HBoxContainer.new()
	_input_row.name = "ChatInput"
	_input_row.add_theme_constant_override("separation", 8)
	_input_row.anchor_left = 0.0
	_input_row.anchor_top = 1.0
	_input_row.anchor_right = 1.0
	_input_row.anchor_bottom = 1.0
	_input_row.offset_left = BOX_MARGIN
	_input_row.offset_right = -BOX_MARGIN
	_anchor.add_child(_input_row)

	# 阶段 5c（2026-10-09）：加号 = **给她发张图** ✓
	# 放输入框左边最顺手（拇指天生够得到 ✓）；点一下直接拉系统选图器 ✓ ——
	# 不做二级菜单：手机上多一层点击没意义 ✓，这儿就只有"发图"这一件事 ✓
	var add := Button.new()
	add.name = "PickPhoto"
	add.text = "＋"
	add.tooltip_text = "给她发张图"
	add.focus_mode = Control.FOCUS_NONE
	add.custom_minimum_size = Vector2(52.0, INPUT_H)
	add.add_theme_font_override("font", _host._cjk_font)
	add.add_theme_font_size_override("font_size", 20)
	add.pressed.connect(_pick_photo)
	_input_row.add_child(add)

	_input = LineEdit.new()
	_input.placeholder_text = "说点什么…"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0.0, INPUT_H)
	_input.add_theme_font_override("font", _host._cjk_font)
	_input.add_theme_font_size_override("font_size", 16)
	_input.text_submitted.connect(func(_t: String) -> void: _send_input())
	_input_row.add_child(_input)

	var send := Button.new()
	send.text = "发送"
	send.focus_mode = Control.FOCUS_NONE
	send.custom_minimum_size = Vector2(78.0, INPUT_H)
	send.add_theme_font_override("font", _host._cjk_font)
	send.add_theme_font_size_override("font_size", 16)
	send.pressed.connect(_send_input)
	_input_row.add_child(send)
	_apply_bottom_offsets()

## 加号：给她发张图（拉系统选图器 ✓）。
## 选完那张图走的是**和系统分享完全相同**的那条链 ✓（见 pet_mobile_share.gd ✓），
## 所以这里只负责"把选图器拉起来"这一件事 ✓
func _pick_photo() -> void:
	if _input != null:
		_input.release_focus()          # 键盘先收：选图器一开、输入框还聚着焦会顶得很难受 ✓
	DisplayServer.virtual_keyboard_hide()
	PetLog.log("分享", "聊天框加号：给她发张图")
	if _host._share != null:
		_host._share.pick_from_gallery()

## 把输入框里的话交给她。发完立刻清空 + 收起键盘（键盘挡着看不清她回了什么）
func _send_input() -> void:
	if _input == null:
		return
	var t := _input.text.strip_edges()
	_input.text = ""
	_input.release_focus()
	DisplayServer.virtual_keyboard_hide()
	if t != "":
		_host._submit_chat(t)

# ------------------------------------------------------------------ 底部对话框

## 把那个"贴底的小气泡"改成 galgame 的文本框：贴底、整条宽度、字号放大、去掉白描边
func _style_bubble() -> void:
	var bubble: Label = _host._bubble
	bubble.add_theme_font_size_override("font_size", FONT_SIZE)
	# 桌面上那圈白描边是为了让字在小窗口里压得住背景；手机上面板本身是浅色不透明的，描边只会糊
	bubble.add_theme_constant_override("outline_size", 0)
	bubble.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
	# 锚到底边：从 9:16 到 9:20 的屏幕它都贴着底，不用跟着改坐标
	bubble.anchor_left = 0.0
	bubble.anchor_top = 1.0
	bubble.anchor_right = 1.0
	bubble.anchor_bottom = 1.0
	bubble.offset_left = BOX_MARGIN
	bubble.offset_right = -BOX_MARGIN
	_apply_bottom_offsets()
	bubble.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	bubble.clip_text = false

## 底部两块（对话框 + 输入行）的纵向偏移。单独抽出来是因为**软键盘弹起时要整体上移**
## （键盘高度由系统给，见 _sync_keyboard）——两处共用一个计算，免得改一处漏一处
func _apply_bottom_offsets() -> void:
	var lift := _kb_lift
	var input_bottom := BOX_MARGIN + lift
	var input_top := BOX_MARGIN + INPUT_H + lift
	var box_bottom := input_top + GAP
	var box_top := box_bottom + BOX_H
	# ⚠️ 对话框的底不是屏幕底，而是**输入行上沿 + 缝隙**（2026-10-08 写错过一次：
	# 写成 -input_bottom 之后两块叠在一起了，差 44 像素）
	_host._bubble.offset_bottom = -box_bottom
	_host._bubble.offset_top = -box_top
	if _input_row != null:
		_input_row.offset_bottom = -input_bottom
		_input_row.offset_top = -input_top

## 名字条（"谁在说话"，galgame 的固定部件）+ 右下角那句"点一下继续"
func _add_parts() -> void:
	_name = Label.new()
	_name.name = "NameTag"
	_name.text = String(_host.chat_persona_name)
	_name.add_theme_font_override("font", _host._cjk_font)
	_name.add_theme_font_size_override("font_size", NAME_SIZE)
	_name.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_name.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.12, 0.85))
	_name.add_theme_constant_override("outline_size", 4)
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor.add_child(_name)

	_hint = Label.new()
	_hint.name = "TapHint"
	_hint.text = "点一下继续"
	_hint.add_theme_font_override("font", _host._cjk_font)
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.35, 0.42, 0.55, 0.75))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor.add_child(_hint)

	# 右上角一个「⚙」：手机上没有右键菜单，设置页得有个门。
	# 44x44 是手指点得着的最小尺寸（Material 建议值），贴右上角不挡她
	var gear := Button.new()
	gear.name = "SettingsButton"
	gear.text = "⚙"
	gear.focus_mode = Control.FOCUS_NONE
	gear.add_theme_font_size_override("font_size", 22)
	gear.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	gear.offset_left = -60.0
	gear.offset_right = -14.0
	gear.offset_top = 14.0
	gear.offset_bottom = 58.0
	gear.pressed.connect(func() -> void: _host.toggle_settings())
	_anchor.add_child(gear)

	# 「聊天记录」入口（2026-10-08）：摆在齿轮左边一个身位。
	# 竖屏顶部那块很空（她在中间），44×44 是手指能按到的下限 ✓
	var log_btn := Button.new()
	log_btn.name = "ChatLogButton"
	log_btn.text = "记录"
	log_btn.add_theme_font_size_override("font_size", 14)
	# ⚠️ 字体在**宿主**身上（`_host._cjk_font`）—— 这个模块自己没有 _cjk_font 字段，
	# 写成 `_cjk_font` 会直接 Parse Error 把整个模块拖垮 ✗（2026-10-08 真踩过）
	var f: Font = _host._cjk_font
	if f != null:
		log_btn.add_theme_font_override("font", f)
	log_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	log_btn.offset_left = -132.0
	log_btn.offset_top = 14.0
	log_btn.offset_right = -132.0 + 58.0
	log_btn.offset_bottom = 14.0 + 44.0
	log_btn.pressed.connect(func() -> void: _host.toggle_chatlog())
	_anchor.add_child(log_btn)

## 她说了一句 → 对话框显示出来（内容还是由宿主的 _say 写进 _bubble.text）
func show_line(_text: String) -> void:
	var bubble: Label = _host._bubble
	if bubble == null:
		return
	bubble.visible = true
	_sync_parts()

## 收起来（点空白处）。她自己会再开口，或者下次摸她
func dismiss_dialog() -> void:
	if _host._bubble == null:
		return
	_host._bubble.visible = false
	_sync_parts()

func is_dialog_visible() -> bool:
	return _host._bubble != null and _host._bubble.visible

## 触感：手机上有"摸到了"的反馈才像在摸东西。桌面上这个调用是空操作，不用分支。
## 设置里能关（有人不喜欢震动）—— 开关在 pet_mobile_settings.haptic
func buzz() -> void:
	if HAPTIC_MS > 0 and bool(_host.haptic_enabled):
		Input.vibrate_handheld(HAPTIC_MS)

# ------------------------------------------------------------------ 每帧

func tick() -> void:
	if _anchor == null or _host._bubble == null:
		return
	_sync_keyboard()
	_sync_parts()
	_layout_comfort()
	_layout_quick()

## 候选条（pet_quick 自己建的 `QuickReplies`）**也照桌面气泡定位** ✗ ——
## 手机上同样会掉到屏幕外，所以这里接管位置和按钮尺寸。
## 它每次显示时会自己 `_place()` 一次，这里是每帧覆盖 —— 谁最后说话谁算
## 结果只依赖这四个量：宽度 / 按钮个数 / 屏幕高 / 键盘抬升。
## **每帧重设 `custom_minimum_size` 和主题字号会让容器重新算最小尺寸并重排** ✗ ——
## 真机实测这一项就是"帧数低"的最大头（本地每帧 3.3ms，手机上约 15ms ✗）。
## 所以包一个签名守卫：没变就一个属性都不碰 ✓
var _quick_sig := Vector4.ZERO

func _layout_quick() -> void:
	var box := _anchor.get_node_or_null("QuickReplies") as Control
	if box == null or not box.visible:
		_quick_sig = Vector4.ZERO       # 藏起来 → 清签名，下次显示重排一次 ✓
		return
	var w: float = _anchor.size.x - BOX_MARGIN * 2.0 - 76.0
	var sig := Vector4(w, float(box.get_child_count()), _anchor.size.y, _kb_lift)
	if sig == _quick_sig:
		return
	_quick_sig = sig
	for c in box.get_children():
		var b := c as Button
		if b == null:
			continue
		b.custom_minimum_size = Vector2(w, BTN_H)
		b.add_theme_font_size_override("font_size", BTN_FONT)
	var bw: float = box.get_combined_minimum_size().x
	var bh: float = box.get_combined_minimum_size().y
	box.position = Vector2((_anchor.size.x - bw) * 0.5, _bottom_stack_top() - 20.0 - bh)

## 底部那一摞（输入行 + 缝隙 + 对话框）的上沿 y。选择框和候选条都贴它上面摆
func _bottom_stack_top() -> float:
	return _anchor.size.y - (BOX_MARGIN + INPUT_H + GAP + BOX_H + _kb_lift)

## 软键盘弹起时把底部那两块（对话框 + 输入行）整体顶上去 ——
## 不然键盘盖住的正是你正在打字的那个框。高度由系统给（DisplayServer）。
## 桌面上这个接口恒返回 0，所以同一份代码在 PC 上跑不会动
func _sync_keyboard() -> void:
	# ⚠️ 必须**先问能力**再问高度（2026-10-08 实测）：Windows 上这个显示服务器没有软键盘，
	# 每次调 `virtual_keyboard_get_height()` 都会吐一条带 **GDScript 调用栈**的引擎警告 ✗，
	# 而那套"拼警告 + 抓 backtrace"每帧要 3.3ms（本地探针量出来的，占每帧脚本耗时的 87% ✗✗）。
	# Android 支持软键盘，所以这条只在开发机上犯病 —— 但一样要挡住 ✓
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return
	var h_phys := float(DisplayServer.virtual_keyboard_get_height())
	# ⚠️⚠️ **物理像素要折成设计坐标**（2026-10-09 用户报"一开始打字，底下的框就看不见了" ✓）：
	#   真机 1260×2800 上报的键盘高度是 **1117 物理像素** ✓，而这个界面跑在
	#   **拉伸后的设计坐标**里（高约 1000 ✓）—— 直接拿 1117 当设计单位去抬 ✗，
	#   等于把整条底栏顶到屏幕外面（日志里那串 991→1053→…→1117 就是这么干的 ✓，
	#   而当时没人看出来问题 —— 因为日志只打了"上移多少"，没打"和屏幕是什么比例" ✗）。
	#   折法：设计高度 / 物理高度 ✓（这台 ≈ 2.8 ✓）
	var phys_h := maxf(1.0, float(DisplayServer.screen_get_size().y))
	var design_h := maxf(1.0, _anchor.size.y) if _anchor != null else 1000.0
	var h := h_phys * design_h / phys_h
	if is_equal_approx(h, _kb_lift):
		return
	var was_up := _kb_lift > 0.0
	_kb_lift = h
	_apply_bottom_offsets()
	# 只在"弹起 / 收起"那一刻记一行 ✓ —— 中间那串动画别刷屏 ✗（原来每帧都记 ✓）
	if (not was_up and h > 0.0) or (was_up and h <= 0.0):
		PetLog.log("界面", "软键盘%s：物理 %.0f px ÷ 比例 %.2f → 设计坐标上移 %.0f ✓" % [
			"弹起" if h > 0.0 else "收起", h_phys, phys_h / design_h, h])

## 名字条 / "点一下继续"跟着对话框走（对话框的位置随屏幕比例变，所以每帧现算）
func _sync_parts() -> void:
	var bubble: Label = _host._bubble
	var on: bool = bubble.visible
	if _name != null:
		if _name.visible != on:
			_name.visible = on
		var np: Vector2 = bubble.position + Vector2(16.0, -26.0)
		if _name.position != np:
			_name.position = np          # 只在真的挪了才 set（每帧 set 也会走一遍脏标记 ✗）
	if _hint != null:
		if _hint.visible != on:
			_hint.visible = on
		var hp: Vector2 = bubble.position + Vector2(bubble.size.x - 92.0, bubble.size.y - 22.0)
		if _hint.position != hp:
			_hint.position = hp

## 把「哄她」选择框摆到手机上该在的地方，并把按钮放大到手指按得着。
##
## **为什么位置要在手机这头管**：pet_mood_ui._show_comfort() 的定位是照**桌面**写的
## （`(2, 气泡下沿 + 2)`）—— 桌面上气泡在上半屏，框落在它下面正好；手机的"气泡"就是屏幕
## 底部那条对话框，于是框必然掉到屏幕外（2026-10-08 真机截图：只露出第一个按钮）。
## 那块是共用模块（桌面也在用），不动它；这里每一帧接管位置和字号 —— 那边只管内容。
##
## ⚠️ 用 `_anchor.size` 而不是常量 DESIGN：手机上 aspect=expand，
## Control 空间比 450×800 高（这台是 450×1000），写死 800 会让框浮在对话框上方老远
var _comfort_sig := Vector4.ZERO

func _layout_comfort() -> void:
	var box := _anchor.get_node_or_null("SulkComfort") as Control
	if box == null or not box.visible:
		_comfort_sig = Vector4.ZERO
		return
	var w: float = _anchor.size.x - BOX_MARGIN * 2.0 - 76.0
	var sig := Vector4(w, float(box.get_child_count()), _anchor.size.y, _kb_lift)
	if sig == _comfort_sig:
		return                          # 同上：没变就一个属性都不碰 ✓
	_comfort_sig = sig
	for c in box.get_children():
		var b := c as Button
		if b == null:
			continue
		b.custom_minimum_size = Vector2(w, BTN_H)
		b.add_theme_font_size_override("font_size", BTN_FONT)
	# 横向居中；纵向摆在她和对话框之间那条空当里（对话框占底部 BOX_H + 留白）
	var bw: float = box.get_combined_minimum_size().x
	var bh: float = box.get_combined_minimum_size().y
	box.position = Vector2((_anchor.size.x - bw) * 0.5, _bottom_stack_top() - 20.0 - bh)
