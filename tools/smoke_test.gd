extends SceneTree
## 冒烟测试：把 pet.tscn 真的跑起来，检查有没有脚本/动画错误，并截图。
## 用法：
##   godot --path <项目> --script res://tools/smoke_test.gd
## 会在项目根目录生成 _smoke_*.png

func _print_extremes(root: Node) -> void:
	var rows: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			var box: AABB = mi.global_transform * mi.get_aabb()
			rows.append([box.position.y + box.size.y, box.position.y, mi.name, str(mi.get_path())])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("最高的 4 个部件：")
	for i in mini(4, rows.size()):
		print("   top=%.3f bottom=%.3f %s" % [rows[i][0], rows[i][1], rows[i][3]])
	print("最低的 3 个部件：")
	for i in mini(3, rows.size()):
		var r: Array = rows[rows.size() - 1 - i]
		print("   top=%.3f bottom=%.3f %s" % [r[0], r[1], r[3]])

func _world_aabb(root: Node) -> AABB:
	var first := true
	var out := AABB()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			var box: AABB = mi.global_transform * mi.get_aabb()
			if first:
				out = box
				first = false
			else:
				out = out.merge(box)
	return out

func _world_min_y(root: Node) -> float:
	var lo := INF
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			var box: AABB = mi.global_transform * mi.get_aabb()
			lo = minf(lo, box.position.y)
	return lo

func _dump(n: Node, depth: int) -> void:
	if depth > 3:
		return
	print("%s%s (%s)" % ["  ".repeat(depth), n.name, n.get_class()])
	for c in n.get_children():
		_dump(c, depth + 1)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# 只跑手机宿主：命令行加 `-- mobile` ✓
	# （桌面那段 420 帧里，每一帧都在重试连不上的 AI ✗ —— 实测能拖几十分钟 ✗；
	#  改手机端时压根不用等它 ✓，直接看 _run_mobile 的结论 ✓）
	if OS.get_cmdline_user_args().has("mobile"):
		await _run_mobile()
		quit(0)
		return
	print("=== 桌宠冒烟测试 ===")
	var packed: PackedScene = load("res://scenes/pet.tscn")
	if packed == null:
		printerr("加载 pet.tscn 失败")
		quit(1)
		return

	var pet: Node = packed.instantiate()
	get_root().add_child(pet)

	var player: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	var face: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer2")
	var cam: Camera3D = pet.get_node_or_null("Camera3D")
	print("--- 场景树 ---")
	_dump(pet, 0)
	print("AnimationPlayer: %s" % ("OK" if player != null else "缺失"))
	print("表情层: %s" % ("OK" if face != null else "缺失"))
	print("Camera3D: %s projection=%d size=%.3f pos=%s" % [
		"OK" if cam != null else "缺失",
		cam.projection if cam != null else -1,
		cam.size if cam != null else 0.0,
		cam.position if cam != null else Vector3.ZERO,
	])

	# 跑一段，让它自己走一会儿，暴露状态机问题
	var frames := 0
	var shots := {}
	while frames < 420:
		await process_frame
		frames += 1
		if frames in [30, 150, 300, 410]:
			var img: Image = get_root().get_texture().get_image()
			var path := "res://_smoke_%03d.png" % frames
			img.save_png(path)
			shots[frames] = path

	print("截图: %s" % [shots.values()])
	# 落地是否成功：角色世界包围盒的最低点应该在 y≈0
	var pivot: Node3D = pet.get_node_or_null("Character/Pivot")
	if pivot != null:
		print("Pivot 抬升 y=%.4f（应约等于 0.694）" % pivot.position.y)
	var foot := _world_min_y(pet)
	print("角色世界最低点 y=%.4f（接近 0 说明已落地）" % foot)
	if cam != null:
		print("相机 current=%s size=%.3f near=%.3f far=%.1f" % [
			cam.current, cam.size, cam.near, cam.far])
		print("视口: %s" % [get_root().get_visible_rect().size])
		# 把角色世界包围盒的 8 个角投影到屏幕，看有没有超出窗口
		var wbox := _world_aabb(pet)
		print("全场景(含阴影)包围盒: pos=%s size=%s" % [wbox.position, wbox.size])
		var mbox := _world_aabb(pet.get_node("Character"))
		print("仅角色包围盒: pos=%s size=%s" % [mbox.position, mbox.size])
		_print_extremes(pet.get_node("Character"))
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for i in 8:
			var w: Vector3 = wbox.get_endpoint(i)
			if cam.is_position_behind(w):
				print("  角 %d 在相机后面: %s" % [i, w])
				continue
			var p: Vector2 = cam.unproject_position(w)
			lo = lo.min(p)
			hi = hi.max(p)
		print("投影到屏幕: min=%s max=%s (窗口 330x470)" % [lo, hi])
	if player != null:
		print("当前动画: %s (player2: %s)" % [player.current_animation, face.current_animation if face != null else "-"])
		print("动画库: %s" % [player.get_animation_library_list()])
		var lib: AnimationLibrary = player.get_animation_library("")
		if lib != null:
			print("动画数量: %d，含合并待机: %s" % [
				lib.get_animation_list().size(), lib.has_animation("__pet_idle")])
	pet.free()
	print("=== OK ===")
	await _run_mobile()
	quit(0)

## 手机宿主冒烟（2026-10-11 加）：工程主场景是 **scenes/mobile/pet_mobile.tscn**
##（project.godot 的 run/main_scene ✓）—— 上面跑的 pet.tscn 是**桌面**那份 ✗，
## 手机宿主的接线（四个全屏面板互斥 / 她不该插嘴的门禁 / 新页面）**只有这里覆盖得到** ✓
func _run_mobile() -> void:
	print("=== 手机宿主冒烟（pet_mobile.tscn）===")
	var packed: PackedScene = load("res://scenes/mobile/pet_mobile.tscn")
	if packed == null:
		printerr("加载 pet_mobile.tscn 失败")
		quit(1)
		return
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	var frames := 0
	while frames < 90:          # 让它把 _ready 那条链走完（记忆/对话/情绪都建起来 ✓）
		await process_frame
		frames += 1
	var bad := 0
	# 四个全屏面板**互斥** ✓（叠在一起遮罩互相压 ✗）
	pet.toggle_memview()
	bad += _want(_is_open(pet, "_memview_ui"), true, "_memview_ui")
	bad += _want(_is_open(pet, "_chatlog_ui"), false, "_chatlog_ui")
	bad += _want(_is_open(pet, "_settings_ui"), false, "_settings_ui")
	bad += _want(_is_open(pet, "_remind_ui"), false, "_remind_ui")
	bad += _want(pet._ui_panel_open(), true, "_ui_panel_open（面板开着 → 她不该插嘴 ✓）")
	pet.toggle_chatlog()
	bad += _want(_is_open(pet, "_memview_ui"), false, "_memview_ui")
	bad += _want(_is_open(pet, "_chatlog_ui"), true, "_chatlog_ui")
	pet.toggle_remind()          # 第二梯队⑧：小本本那页也进来一起验 ✓
	bad += _want(_is_open(pet, "_chatlog_ui"), false, "_chatlog_ui")
	bad += _want(_is_open(pet, "_remind_ui"), true, "_remind_ui")
	pet.toggle_settings()
	bad += _want(_is_open(pet, "_remind_ui"), false, "_remind_ui")
	bad += _want(_is_open(pet, "_settings_ui"), true, "_settings_ui")
	pet.toggle_settings()      # 再点一下收起 ✓
	bad += _want(_is_open(pet, "_settings_ui"), false, "_settings_ui")
	bad += _want(pet._ui_panel_open(), false, "_ui_panel_open（全收了 → 又能说话了 ✓）")
	# 阶段⑤（2026-10-11）：桌面小组件那一行 ✓
	# （非安卓上 wrap 不出 PetBridge ✓ → _widget_note 只落文件 ✓，正好验文件格式 ✓ ——
	#  Java 侧 PetWidget.readLine 按"第一行句子、第二行 unix 秒"读 ✓）
	pet._widget_note("冒烟测试的一句")
	var wf := FileAccess.open("user://widget_line.txt", FileAccess.READ)
	bad += _want(wf != null, true, "widget_line.txt 写出来了")
	if wf != null:
		var wl1 := wf.get_line()
		var wl2 := wf.get_line()
		wf.close()
		bad += _want(wl1, "冒烟测试的一句", "卡片第一行 = 她的话")
		bad += _want(wl2.is_valid_int(), true, "卡片第二行 = unix 秒")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://widget_line.txt"))
	pet.free()
	if bad > 0:
		print("=== 手机宿主：%d 项不符 ===" % bad)
		quit(1)
		return
	print("=== 手机宿主 OK ===")

func _is_open(pet: Node, prop: String) -> bool:
	var ui: Variant = pet.get(prop)
	return ui != null and ui.is_open()

func _want(got: Variant, want: Variant, what: String) -> int:
	var ok: bool = got == want
	print("  %s = %s（想要 %s）%s" % [what, str(got), str(want), "✓" if ok else "✗"])
	return 0 if ok else 1
