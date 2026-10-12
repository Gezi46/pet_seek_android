# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验 2026-10-11 第二梯队⑧「提醒事项」（pet_mobile_remind.gd）：
##
##   A 段 parse：各种说法认不认得出、认出的时间对不对、认不出当没这事 ✓
##   B 段 增删查：add/remove/mark_done/due_open/due_within/all 的排序 ✓ + 落盘重读 ✓
##   C 段 reconcile：回前台只划"后台真排上的"✓，没排的不划 ✓（她答应的事不能没 ✗）
##   D 段 when_text：今天/明天/后天/远日子四种一眼时间 ✓
##
## 用法（不联网，几秒出结果 ✓）：
##   & $godot --headless --path . --script res://tools/probe_remind.gd

extends SceneTree

const PetMobileRemind := preload("res://scripts/mobile/pet_mobile_remind.gd")

## 看门狗：--script 模式下不主动 quit 进程会一直挂着（README 第 9 条坑）
const MAX_FRAMES := 60 * 30

## 探针专用的小本本文件（跑完删掉，**不动真数据** ✓ —— 口径同 probe_daily 的 TMP_MEM ✓）
const TMP := "user://_probe_remind.json"

var _frames := 0
var _ok := 0
var _bad := 0
var _done := false

func _initialize() -> void:
	# 钉死"现在"：2026-10-11（周日）10:00:00 —— 解析的断言全靠它 ✓
	var now := _now(10)
	var now_ts: float = Time.get_unix_time_from_datetime_dict(now)
	_a_api(now)
	_a_parse(now, now_ts)
	_b_ops(now_ts)
	_c_reconcile(now_ts)
	_d_when_text()
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

func _now(h: int, mth: int = 10, d: int = 11, y: int = 2026, mi: int = 0) -> Dictionary:
	return {"year": y, "month": mth, "day": d, "hour": h, "minute": mi, "second": 0}

func _ts(h: int, d: int = 11, mi: int = 0) -> float:
	return Time.get_unix_time_from_datetime_dict(_now(h, 10, d, 2026, mi))

## 认一句 → {"text": ..., "due": ...}；认不出给空 ✓
func _p(s: String, now: Dictionary) -> Dictionary:
	var r := PetMobileRemind.new()
	return r.parse(s, now)

# ------------------------------------------------------------------ A 段：API + parse

func _a_api(now: Dictionary) -> void:
	print("── A0：时间 API 本身（反向那个函数真存在 ✓）")
	# 模块全靠 Time.get_unix_time_from_datetime_dict（字典 → unix 秒 ✓）。
	# 探针的职责就是**别猜**：真调一次，来回对得上才算数 ✓
	var back: Dictionary = Time.get_datetime_dict_from_unix_time(
		int(Time.get_unix_time_from_datetime_dict(now)))
	_check("来回一致（年", back["year"], 2026)
	_check("月", back["month"], 10)
	_check("日", back["day"], 11)
	_check("时", back["hour"], 10)
	_check("分", back["minute"], 0)

func _a_parse(now: Dictionary, now_ts: float) -> void:
	print("── A 段：parse 各种说法 ✓")
	# ① 相对时间（阿拉伯 + 中文数词都要认 ✓ —— "两分钟"比"2 分钟"像人话 ✓）
	var r := _p("提醒我十分钟后开会", now)
	_check("十分钟后·事儿", r.get("text", ""), "开会")
	_check("十分钟后·时间", r.get("due", -1.0), now_ts + 600.0)
	r = _p("半小时后叫我吃药", now)
	_check("半小时后·事儿", r.get("text", ""), "吃药")
	_check("半小时后·时间", r.get("due", -1.0), now_ts + 1800.0)
	r = _p("两分钟后提醒我关火", now)
	_check("两分钟后·事儿", r.get("text", ""), "关火")
	_check("两分钟后·时间", r.get("due", -1.0), now_ts + 120.0)
	r = _p("三个钟头后提醒我浇水", now)
	_check("三个钟头后·事儿", r.get("text", ""), "浇水")
	_check("三个钟头后·时间", r.get("due", -1.0), now_ts + 10800.0)
	# ② 绝对时间：时段词 + 中文/阿拉伯数词、12 小时制、过了顺延 ✓
	r = _p("明天早上八点提醒我起床", now)
	_check("明天早上八点·事儿", r.get("text", ""), "起床")
	_check("明天早上八点·时间", r.get("due", -1.0), _ts(8, 12))
	r = _p("提醒我下午3点开会", now)
	_check("下午3点·事儿（下午 3 = 15 点 ✓）", r.get("text", ""), "开会")
	_check("下午3点·时间", r.get("due", -1.0), _ts(15, 11))
	r = _p("叫我晚上八点遛狗", now)
	_check("晚上八点·事儿", r.get("text", ""), "遛狗")
	_check("晚上八点·时间", r.get("due", -1.0), _ts(20, 11))
	r = _p("提醒我8点吃饭", now)          # 10 点说的"8 点" → 已经过了 → 明早 ✓
	_check("8点已过·顺延明天", r.get("due", -1.0), _ts(8, 12))
	_check("8点已过·事儿", r.get("text", ""), "吃饭")
	r = _p("叫我中午12点半吃饭", now)
	_check("12点半·时间（12 点本身不 +12 ✓）", r.get("due", -1.0), _ts(12, 11, 30))
	r = _p("提醒我凌晨12点睡觉", now)      # 凌晨 12 点 = 0 点 → 也过了 → 明天 0 点 ✓
	_check("凌晨12点·时间", r.get("due", -1.0), _ts(0, 12))
	r = _p("叫我后天晚上八点取快递", now)
	_check("后天晚上八点·时间", r.get("due", -1.0), _ts(20, 13))
	_check("后天晚上八点·事儿", r.get("text", ""), "取快递")
	# ③ 认不出就当没这事 ✓（猜错时间比不记更糟 ✗）
	_check("没有提醒/叫我", _p("今天天气不错", now).is_empty(), true)
	_check("没有时间", _p("提醒我多喝水", now).is_empty(), true)
	_check("有时间没事儿", _p("提醒我8点", now).is_empty(), true)

# ------------------------------------------------------------------ B 段：增删查 + 落盘

func _b_ops(now_ts: float) -> void:
	print("── B 段：增删查 ✓")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	var r := PetMobileRemind.new()
	r.file_path = TMP                # 指到临时文件，别把真小本本当实验品 ✓
	r.load()
	_check("空盘开局", r.count_open(), 0)
	var a := r.add("开会", now_ts + 600.0)
	var b := r.add("吃药", now_ts + 300.0)
	var c := r.add("遛狗", now_ts + 3600.0)
	_check("id 从 1 起", [a.id, b.id, c.id], [1, 2, 3])
	_check("三条都没说", r.count_open(), 3)
	_check("还没到点", r.due_open(now_ts).size(), 0)
	var due: Array = r.due_open(now_ts + 400.0)
	_check("到点一条（吃药）", due.size(), 1)
	_check("到点那条是吃药", (due[0] as PetMobileRemind.Item).text, "吃药")
	_check("到点两条", r.due_open(now_ts + 700.0).size(), 2)
	# due_within：窗口内的、按到点排 ✓
	var win: Array = r.due_within(500.0, now_ts)
	_check("窗口内一条", win.size(), 1)
	_check("窗口那条是吃药", (win[0] as PetMobileRemind.Item).text, "吃药")
	win = r.due_within(3600.0, now_ts)
	_check("窗口内三条（按到点排 ✓）", [
		(win[0] as PetMobileRemind.Item).text,
		(win[1] as PetMobileRemind.Item).text,
		(win[2] as PetMobileRemind.Item).text], ["吃药", "开会", "遛狗"])
	# all()：没说的在前按到点升序 ✓
	var all: Array = r.all()
	_check("all 顺序", [
		(all[0] as PetMobileRemind.Item).text,
		(all[1] as PetMobileRemind.Item).text,
		(all[2] as PetMobileRemind.Item).text], ["吃药", "开会", "遛狗"])
	# 说过的沉到最后 ✓
	r.mark_done(a.id)
	all = r.all()
	_check("说过的沉底", (all[2] as PetMobileRemind.Item).text, "开会")
	_check("说过的沉底·done", (all[2] as PetMobileRemind.Item).done, true)
	# 删 + 乱 id 删不动 ✓
	_check("删掉遛狗", r.remove(c.id), true)
	_check("乱 id 删不动", r.remove(999), false)
	_check("剩两条", r.items.size(), 2)
	# 落盘 → 新实例读回来 ✓
	var r2 := PetMobileRemind.new()
	r2.file_path = TMP
	r2.load()
	_check("读盘：两条", r2.items.size(), 2)
	_check("读盘：一条没说", r2.count_open(), 1)
	_check("读盘：那条是吃药", (r2.all()[0] as PetMobileRemind.Item).text, "吃药")

# ------------------------------------------------------------------ C 段：对账

func _c_reconcile(now_ts: float) -> void:
	print("── C 段：reconcile 只划排上的 ✓")
	var r := PetMobileRemind.new()
	r.file_path = TMP
	r.load()                          # 接着 B 段：吃药开着、开会说过了
	# 没排名单 → 一条都不划 ✓（不然她答应的事悄没声地没了 ✗）
	_check("没排名单：划掉几条", r.reconcile(now_ts + 100000.0), 0)
	_check("没排名单：吃药还开着", r.count_open(), 1)
	# 排上了 → 划掉 ✓
	r.mark_scheduled([(r.all()[0] as PetMobileRemind.Item).id])
	_check("排上了：划掉几条", r.reconcile(now_ts + 100000.0), 1)
	_check("排上了：吃药也划了", r.count_open(), 0)
	# 名单划完就清 → 再调不重复划 ✓
	_check("名单清了", r.reconcile(now_ts + 100000.0), 0)
	# 新加一条到点的、**没排** → 不划（回来该由 tick 补喊 ✓）
	r.add("取快递", now_ts + 10.0)
	_check("没排的不划", r.reconcile(now_ts + 100000.0), 0)
	_check("取快递还开着", r.count_open(), 1)

# ------------------------------------------------------------------ D 段：when_text

func _d_when_text() -> void:
	print("── D 段：when_text 一眼时间 ✓")
	var today := Time.get_datetime_dict_from_system()
	var t0: float = Time.get_unix_time_from_datetime_dict({
		"year": int(today["year"]), "month": int(today["month"]), "day": int(today["day"]),
		"hour": 0, "minute": 0, "second": 0})
	_check("今天", PetMobileRemind.when_text(t0 + 15.0 * 3600.0), "今天 15:00")
	_check("明天", PetMobileRemind.when_text(t0 + 86400.0 + 8.0 * 3600.0), "明天 08:00")
	_check("后天", PetMobileRemind.when_text(t0 + 2.0 * 86400.0 + 9.0 * 3600.0 + 1800.0), "后天 09:30")
	_check("远日子", PetMobileRemind.when_text(
		Time.get_unix_time_from_datetime_dict(_now(9, 3, 5, 2027, 5))), "03-05 09:05")
	# 收尾：临时文件删掉 ✓
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	_check("临时文件已删", FileAccess.file_exists(TMP), false)
	print("  （探针用的 _probe_remind.json 已删 ✓）")
