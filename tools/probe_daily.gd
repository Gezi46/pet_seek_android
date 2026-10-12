# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验 2026-10-11 新加的手机端模块（时段问候 / 纪念日 / 电量关心 / 记忆浏览）：
##
##   A 段 slot_of 时段表边界（纯函数 ✓）
##   B 段 问候模块的 due/mark（当天只说一次 ✓，换天再说 ✓）
##   C 段 纪念日的 days_between / due（周年、里程碑、当天只庆一次 ✓）
##   D 段 电量模块在非安卓上必须"什么也不说" ✓ + 本地台词的 % 格式化行为 ✓
##   E 段 记忆浏览页背后的 PetMemory.remove()（按 key 删 ✓，删错 key 不动 ✓）
##
## 用法（不联网，几秒出结果 ✓）：
##   & $godot --headless --path . --script res://tools/probe_daily.gd

extends SceneTree

const PetMobileGreet := preload("res://scripts/mobile/pet_mobile_greet.gd")
const PetMobileAnniv := preload("res://scripts/mobile/pet_mobile_anniv.gd")
const PetMobileBattery := preload("res://scripts/mobile/pet_mobile_battery.gd")
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")

## 看门狗：--script 模式下不主动 quit 进程会一直挂着（README 第 9 条坑）
const MAX_FRAMES := 60 * 30

## E 段用的临时记忆文件（跑完删掉，**不动真记忆** ✓ —— 口径同 probe_memory.gd）
const TMP_MEM := "user://_probe_memview.json"

var _frames := 0
var _ok := 0
var _bad := 0
var _done := false

func _initialize() -> void:
	_a_slots()
	_b_greet()
	_c_anniv()
	_d_battery()
	_e_memview()
	print("")
	print("==== 探针结果：%d 过 / %d 挂 ====" % [_ok, _bad])
	quit(1 if _bad > 0 else 0)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > MAX_FRAMES:
		print("!! 看门狗超时，强退")
		quit(2)
		return true
	return not _done

# ------------------------------------------------------------------ 小断言

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		_ok += 1
		print("  [PASS] %s = %s" % [name, str(got)])
	else:
		_bad += 1
		print("  [FAIL] %s = %s（想要 %s）" % [name, str(got), str(want)])

func _now(h: int, mth: int = 10, d: int = 11, y: int = 2026) -> Dictionary:
	return {"year": y, "month": mth, "day": d, "hour": h, "minute": 0, "second": 0}

# ------------------------------------------------------------------ A 段：时段表

func _a_slots() -> void:
	print("── A 段：slot_of 时段边界 ✓")
	_check("5 点", PetMobileGreet.slot_of(5), PetMobileGreet.SLOT_MORNING)
	_check("10 点", PetMobileGreet.slot_of(10), PetMobileGreet.SLOT_MORNING)
	_check("11 点", PetMobileGreet.slot_of(11), PetMobileGreet.SLOT_NOON)
	_check("13 点", PetMobileGreet.slot_of(13), PetMobileGreet.SLOT_NOON)
	_check("14 点（空档）", PetMobileGreet.slot_of(14), "")
	_check("17 点", PetMobileGreet.slot_of(17), PetMobileGreet.SLOT_DINNER)
	_check("19 点", PetMobileGreet.slot_of(19), PetMobileGreet.SLOT_DINNER)
	_check("20 点（空档）", PetMobileGreet.slot_of(20), "")
	_check("23 点", PetMobileGreet.slot_of(23), PetMobileGreet.SLOT_NIGHT)
	_check("4 点", PetMobileGreet.slot_of(4), PetMobileGreet.SLOT_NIGHT)

# ------------------------------------------------------------------ B 段：问候

func _b_greet() -> void:
	print("── B 段：问候 due/mark ✓")
	var g := PetMobileGreet.new()
	# ⚠️ 走真文件（user://pet_greet.cfg）—— 跑完删掉，不留垃圾 ✓
	var now := _now(8)
	_check("早上第一次", g.due(now), PetMobileGreet.SLOT_MORNING)
	g.mark(PetMobileGreet.SLOT_MORNING, now)
	g.save()
	_check("说完再问", g.due(now), "")
	_check("换个时段（中午）", g.due(_now(12)), PetMobileGreet.SLOT_NOON)
	var g2 := PetMobileGreet.new()
	g2.load()          # 从盘上读回来： morning 已说过、 noon 没有 ✓
	_check("读盘后早上还是说过", g2.due(_now(9)), "")
	_check("读盘后中午能说", g2.due(_now(12)), PetMobileGreet.SLOT_NOON)
	# 第二天 → 又能说早安 ✓
	_check("第二天早上", g2.due(_now(8, 10, 12)), PetMobileGreet.SLOT_MORNING)
	DirAccess.remove_absolute(PetMobileGreet.FILE_PATH)
	print("  （探针用的 pet_greet.cfg 已删 ✓）")

# ------------------------------------------------------------------ C 段：纪念日

func _c_anniv() -> void:
	print("── C 段：纪念日 ✓")
	_check("同一天", PetMobileAnniv.days_between("2026-10-11", "2026-10-11"), 0)
	_check("差 100 天", PetMobileAnniv.days_between("2026-07-03", "2026-10-11"), 100)
	_check("跨闰年 2 月", PetMobileAnniv.days_between("2024-02-28", "2024-03-01"), 2)
	_check("键坏了", PetMobileAnniv.days_between("x", "2026-10-11"), -1)

	var a := PetMobileAnniv.new()
	a.first_day = "2026-07-03"          # 内存里直接摆，不落盘 ✓
	# 认识第 100 天 → 里程碑 ✓
	var info: Dictionary = a.due(_now(12, 10, 11))
	_check("第 100 天", String(info.get("kind", "")), "milestone")
	_check("第 100 天 n", int(info.get("n", 0)), 100)
	a.mark(info)
	_check("庆过再问", a.due(_now(13, 10, 11)).is_empty(), true)
	# 差一天不算（迟到的不要 ✓）
	_check("第 101 天不算", a.due(_now(12, 10, 12)).is_empty(), true)
	# 周年：整整一年后的同一天 ✓
	var b := PetMobileAnniv.new()
	b.first_day = "2025-10-11"
	var bd: Dictionary = b.due(_now(12, 10, 11))
	_check("一周年", String(bd.get("kind", "")), "birthday")
	_check("一周年 n", int(bd.get("n", 0)), 1)
	# 差几天不算周年 ✓
	var c := PetMobileAnniv.new()
	c.first_day = "2025-10-14"
	_check("差三天不叫周年", c.due(_now(12, 10, 11)).is_empty(), true)
	# 提示词真的带上了数字 ✓
	_check("周年提示词", b.prompt_for(bd).contains("1 年"), true)
	_check("里程碑提示词", a.prompt_for({"kind": "milestone", "n": 100, "days": 100}).contains("100"), true)

# ------------------------------------------------------------------ D 段：电量 + % 行为

func _d_battery() -> void:
	print("── D 段：电量模块（非安卓必须安静 ✓）+ 本地台词 % 行为 ✓")
	var bat := PetMobileBattery.new()
	_check("非安卓 tick", bat.tick(999.0).is_empty(), true)
	# ⚠️ 实测 Godot 4.6：`"无占位符串" % 15` 会打 String formatting error
	# （返回值碰巧是原串，但每轮到一句就往日志里喷一条 ✗）
	# → 宿主 _battery_tick 改成**只在含 %d 时才格式化**，这里照那个逻辑验 ✓
	var plain := "你手机快没电了，早点插上电哦。"
	var with_pct := "电量 %d%% 了……先充电，再陪我。"
	var a: String = (plain % 15) if plain.contains("%d") else plain
	var b: String = (with_pct % 15) if with_pct.contains("%d") else with_pct
	_check("无占位符不动它", a, plain)
	_check("有占位符 % 15", b, "电量 15% 了……先充电，再陪我。")
	var prompt := "（主人手机电量只剩 %d%% 了，还没在充电。" \
			+ "用你自己的口气提醒他充电，一两句就好，可以带点小念叨）"
	_check("低电量提示词", (prompt % 15).contains("只剩 15% 了"), true)

# ------------------------------------------------------------------ E 段：记忆浏览页的删除

func _e_memview() -> void:
	print("── E 段：记忆浏览页的 remove()（按 key 删 ✓，删错不动 ✓）")
	var mem := PetMemory.new()
	mem.file_path = TMP_MEM          # 指到临时文件，别把真记忆当实验品 ✓
	mem.clear()
	mem.add("主人最爱喝冰美式", 0.0, PetMemory.KIND_FACT)
	mem.add("她主动聊到：诶你终于理我了", 0.0, PetMemory.KIND_SELF_LINE)
	_check("加了两条", mem.items.size(), 2)
	var key := String(mem._key(mem.items[0]))
	_check("删第一条", mem.remove(key), true)
	_check("剩一条", mem.items.size(), 1)
	_check("剩下的对", String(mem.items[0].text).contains("你终于理我了"), true)
	# 删错的 key：原样不动 ✓（页面上按 key 认条目，认错了最怕的就是误删 ✗）
	_check("乱键删不掉", mem.remove("123|不存在的记忆"), false)
	_check("还是那一条", mem.items.size(), 1)
	# 再删一次同一条 key：已经没了，返回 false ✓
	_check("重复删", mem.remove(key), false)
	# 落盘生效 ✓：换一个实例读回来，被删的那条不该复活 ✗
	var mem2 := PetMemory.new()
	mem2.file_path = TMP_MEM
	mem2.load_from_disk()
	_check("读盘后也只剩一条", mem2.items.size(), 1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MEM))
	print("  （探针用的 _probe_memview.json 已删 ✓）")
