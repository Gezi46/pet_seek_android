extends RefCounted
## 记忆浏览页（2026-10-11，第二梯队⑥"她记得"可见化）：
## 把她记住的事摊开给人看 —— 档案卡（只读 ✓）+ 一条条记忆（可「忘掉」✓）。
##
## 骨架**照抄 pet_mobile_chatlog_ui.gd**（同一套：全屏 Control + 半透明遮罩 +
## 居中 VBox 面板 + **首次 open 才建**，之后只切 visible ✓）→ 观感和设置页/
## 聊天记录页一致 ✓，没打开时一个控件都没建、每帧零开销 ✓
##
## 为什么逐条一个「忘掉」按钮、而不是长按或多选：手机上就一个手指头，
## **看得见的删除**才是最不容易误触的删除 ✓（删一条存一次盘，条数不多 ✓）
##
## 条目身份用 `memory._key()`（created|text）而不是下标：页面上显示的顺序和
## 内存数组未必一致（以后要排序/筛选就错位了 ✗），键才是稳的 ✓

const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")

const ROW_FONT := 15
const TIME_FONT := 11
const PANEL_X := 25.0
const PANEL_TOP := 96.0
const PANEL_W := 400.0
const BOTTOM_RESERVE := 150.0      # 给底部对话框/输入行留出来

## 种类 → 给人看的一眼词 + 颜色（self_line 是她自己的话、mood 是情绪 ✓）
const KIND_LABEL := {
	PetMemory.KIND_FACT: "关于你",
	PetMemory.KIND_SELF_LINE: "她的话",
	PetMemory.KIND_MOOD: "心情",
}
const KIND_COLOR := {
	PetMemory.KIND_FACT: Color(0.78, 0.84, 0.95),
	PetMemory.KIND_SELF_LINE: Color(0.98, 0.82, 0.86),
	PetMemory.KIND_MOOD: Color(0.85, 0.78, 0.98),
}

var _host: Node = null
var _root: Control = null
var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _empty: Label = null
var _stats: Label = null
var _profile: Label = null
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
	_root.name = "MemViewPage"
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

	panel.add_child(_label("她记得的事", 20, Color(0.95, 0.96, 1.0)))

	# 档案卡（只读 ✓）：名字/喜好这些"关于你"的结论 —— 她记得的你 ✓
	_profile = _label("", 13, Color(0.85, 0.9, 1.0))
	panel.add_child(_profile)

	_stats = _label("", 13, Color(0.7, 0.74, 0.82))
	panel.add_child(_stats)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_W, maxf(anchor.size.y - PANEL_TOP - BOTTOM_RESERVE - 60.0, 200.0))
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(PANEL_W - 12.0, 0)
	_list.add_theme_constant_override("separation", 6)
	_scroll.add_child(_list)

	_empty = _label("她还没有记住什么 —— 跟她聊聊天，这里就会慢慢满起来 ✓", 13, Color(0.7, 0.74, 0.82))
	panel.add_child(_empty)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	row.add_child(_button("关闭", close))

## 忘掉一条（条目身份是 created|text 那条键 ✓）
func _on_forget(key: String) -> void:
	var mem: Variant = _host.memory
	if mem == null:
		return
	mem.remove(key)
	_refresh()

## 层号 → 给人看的一眼词（层号真源在 pet_memory_forget.Layer ✓）
func _layer_name(layer: int) -> String:
	match layer:
		PetMemory.Layer.CORE:
			return "核心"
		PetMemory.Layer.IMPORTANT:
			return "重要"
		_:
			return "常规"

## unix 时间 → "MM-DD"（翻记忆时看个日子就够 ✓）
func _day(ts: float) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%02d-%02d" % [int(dt["month"]), int(dt["day"])]

func _refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	var mem: Variant = _host.memory
	if mem == null:
		# 记忆功能没开（设置里关着 ✓）—— 这一页就是空的，别造一堆控件 ✗
		_profile.text = ""
		_stats.text = ""
		_empty.text = "记忆功能关着 —— 到设置里打开，她才会记住事 ✓"
		_empty.visible = true
		return
	var st: Dictionary = mem.stats()
	if _stats != null:
		_stats.text = "共 %d 条 · 核心 %d · 重要 %d · 常规 %d" % [
			int(st.get("total", 0)), int(st.get("core", 0)),
			int(st.get("important", 0)), int(st.get("regular", 0))]
	if _profile != null:
		var pt := String(mem.profile_text()).strip_edges()
		_profile.text = pt
		_profile.visible = pt != ""
	var items: Array = mem.items
	if _empty != null:
		_empty.visible = items.is_empty()
	for it in items:
		if not (it is PetMemory.Item):
			continue
		var kind := String(it.kind)
		if kind == "":
			kind = PetMemory.KIND_FACT      # 旧条目没这个字段，先当"关于你"显示 ✓
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var kc: Variant = KIND_COLOR.get(kind, KIND_COLOR[PetMemory.KIND_FACT])
		col.add_child(_label(String(it.text), ROW_FONT, kc))
		col.add_child(_label("%s · %s · %s" % [
			_layer_name(int(it.layer)),
			String(KIND_LABEL.get(kind, "关于你")),
			_day(float(it.created))], TIME_FONT, Color(0.6, 0.64, 0.72)))
		row.add_child(col)
		row.add_child(_button("忘掉", _on_forget.bind(String(mem._key(it)))))
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
