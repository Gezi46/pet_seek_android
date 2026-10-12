extends RefCounted
## 提醒事项页（2026-10-11，第二梯队⑧"到点喊你"）：她的小本本，翻给人看 ✓
##
## 骨架**照抄 pet_mobile_memview_ui.gd**（全屏 Control + 半透明遮罩 + VBox 面板 +
## 首次 open 才建 ✓）→ 三个页面观感一致 ✓
##
## **添加不在这儿** ✗ —— 跟她说一句"提醒我十分钟后开会"她就记下了 ✓
##（解析在 pet_mobile_remind.parse ✓；这一页只管看和删 ✓）
## 为什么删掉用 id 而不是下标：页面上按到点排过序，下标和内存数组对不上 ✗

const PetMobileRemind := preload("res://scripts/mobile/pet_mobile_remind.gd")

const ROW_FONT := 15
const TIME_FONT := 11
const PANEL_X := 25.0
const PANEL_TOP := 96.0
const PANEL_W := 400.0
const BOTTOM_RESERVE := 150.0      # 给底部对话框/输入行留出来

var _host: Node = null
var _root: Control = null
var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _empty: Label = null
var _font: Font = null

func setup(host: Node) -> void:
	_host = host

func is_open() -> bool:
	return _root != null and _root.visible

func toggle() -> void:
	if is_open():
		close()
	else:
		open()

func open() -> void:
	if _root == null:
		_build()
	if _root == null:
		return
	_refresh()
	_root.visible = true

func close() -> void:
	if _root != null:
		_root.visible = false

func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(72, 36)
	b.add_theme_font_size_override("font_size", TIME_FONT + 1)
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.pressed.connect(cb)
	return b

func _build() -> void:
	var anchor := _host.get_node_or_null("UI/Anchor") as Control
	if anchor == null:
		return
	_font = _host._cjk_font
	_root = Control.new()
	_root.name = "RemindPage"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	anchor.add_child(_root)

	var scrim := ColorRect.new()
	scrim.color = Color(0.06, 0.08, 0.12, 0.88)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP    # 挡住"点到她"（遮罩下不该还能摸到她 ✓）
	_root.add_child(scrim)

	var panel := VBoxContainer.new()
	panel.position = Vector2(PANEL_X, PANEL_TOP)
	panel.custom_minimum_size = Vector2(PANEL_W, 0)
	panel.add_theme_constant_override("separation", 8)
	_root.add_child(panel)

	panel.add_child(_label("提醒事项", 20, Color(0.95, 0.96, 1.0)))
	panel.add_child(_label("跟她说「提醒我十分钟后开会」她就记下了 ✓ 到点她喊你 ✓", 12, Color(0.7, 0.74, 0.82)))

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_W, maxf(anchor.size.y - PANEL_TOP - BOTTOM_RESERVE - 40.0, 200.0))
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(PANEL_W - 12.0, 0)
	_list.add_theme_constant_override("separation", 6)
	_scroll.add_child(_list)

	_empty = _label("还没有提醒 —— 跟她念叨一句就行 ✓", 13, Color(0.7, 0.74, 0.82))
	panel.add_child(_empty)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	row.add_child(_button("关闭", close))

## 删一条（按 id ✓ —— 页面上排过序，下标会错位 ✗）
func _on_remove(id: int) -> void:
	# ⚠️ 显式 Variant ✗ —— `:=` 推断不了（_host._remind 没有静态类型 ✓，
	# 这条在 memview 那边栽过一次 ✓）
	var mem: Variant = _host._remind
	if mem == null:
		return
	mem.remove(id)
	_refresh()

func _refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	var mem: Variant = _host._remind
	if mem == null:
		_empty.text = "提醒模块没起来 ✗（这不该发生 —— 重启她一下试试 ✓）"
		_empty.visible = true
		return
	var rows: Array = mem.all()
	if _empty != null:
		_empty.visible = rows.is_empty()
	for it in rows:
		if not (it is PetMobileRemind.Item):
			continue
		var done: bool = it.done
		var when: String = PetMobileRemind.when_text(it.due)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 说过的置灰 ✓（她还记着这事，只是不再喊第二遍 ✓）
		var text_col := Color(0.78, 0.84, 0.95) if not done else Color(0.5, 0.53, 0.6)
		col.add_child(_label(String(it.text), ROW_FONT, text_col))
		col.add_child(_label(("✓ 到点说过了 ｜ " if done else "") + when,
			TIME_FONT, Color(0.6, 0.64, 0.72)))
		row.add_child(col)
		row.add_child(_button("删掉", _on_remove.bind(int(it.id))))
		_list.add_child(row)
	_scroll_to_bottom()

## 滚到底：必须等一帧 —— 刚 add_child 的控件还没算出尺寸，这时候设 scroll 是无效的 ✓
func _scroll_to_bottom() -> void:
	if _scroll == null or _host == null:
		return
	var tree := _host.get_tree()
	if tree == null:
		return
	await tree.process_frame
	if _scroll != null:
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
