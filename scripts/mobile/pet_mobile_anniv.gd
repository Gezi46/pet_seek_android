extends RefCounted
## 日志（每个用到的文件都得自己 preload —— 常量不跨文件继承 ✓）
const PetLog := preload("res://scripts/sys/pet_log.gd")
## 手机端「纪念日」（2026-10-11）：她遇见你的那天、认识满 N 天、一年又一年。
##
## 为什么值得做：陪伴感的一半是"被记得" ✓ —— 不光她记得你，
## 你也希望她**记得你们俩的日子** ✓。第一次启动那天会被记下来（相遇日 ✓），
## 到周年、满 100 天、满 520 天这些日子，她会主动提一句 ✓。
##
## ⚠️ 三条规矩（都是踩过的思维方式 ✓）：
##   ① **当天只说一次**（落盘记着说没说过 ✓，重启不重复 ✓）——
##      第二天再打开也不会补一句"昨天是…" ✗（迟到的祝福比没有更怪 ✓）
##   ② 台词**不给具体事**（"第 100 天"这种数字行，编场景不行 ✓）——
##      和第 9b 条同一个教训：照本子念可以，瞎编不行 ✓
##   ③ 没到整年不算周年（第 1 年起 ✓）—— 刚认识三天就周年是笑话 ✗
##
## 落盘：`user://pet_anniv.cfg`：
##   {"anniv": {"first_day": "2026-10-11", "last_n": 100}}
## first_day 空 = 第一次启动（load 时补上今天 ✓，见 ensure ✓）

const FILE_PATH := "user://pet_anniv.cfg"
const SECTION := "anniv"

## 值得庆祝的"认识第 N 天"（不含周年 —— 周年按月/日单独判 ✓）。
## 7/30 是开头，100/520/1314 是梗，365×k 交给 yearly 那条 ✓
const MILESTONES: Array[int] = [7, 30, 100, 365, 520, 777, 1000, 1314, 2000]

## 周年提示词（n = 第几年 ✓）。只给事实，口气归她 ✓
const PROMPT_BIRTHDAY := "（今天是主人认识你整整 %d 年的日子。" \
	+ "用你自己的口气说一句，一两句就好，别太煽情，就像你平时的口气）"
## 里程碑提示词（n = 第几天 ✓）
const PROMPT_MILESTONE := "（今天是主人认识你的第 %d 天。" \
	+ "用你自己的口气顺口提一句，一两句就好，别写成汇报）"

## 本地台词（离线兜底 ✓）。%d = 年数 / 天数 ✓
const LOCAL_BIRTHDAY := [
	"今天是我们认识 %d 年的日子呀。",
	"%d 年前的今天，我们就在一起啦。",
]
const LOCAL_MILESTONE := [
	"今天是我们认识第 %d 天。",
	"都认识 %d 天了。谢谢你还在。",
]

## "YYYY-MM-DD" → 当地午夜的 unix 秒（纯函数 ✓，探针直接验 ✓）
static func day_unix(y: int, m: int, d: int) -> float:
	return Time.get_unix_time_from_datetime_dict({
		"year": y, "month": m, "day": d, "hour": 0, "minute": 0, "second": 0})

## 两个日期键相差几天（first → now，整数天 ✓）。键格式不对给 -1 ✓
static func days_between(first_key: String, now_key: String) -> int:
	var a := first_key.split("-")
	var b := now_key.split("-")
	if a.size() != 3 or b.size() != 3:
		return -1
	if not a[0].is_valid_int() or not a[1].is_valid_int() or not a[2].is_valid_int():
		return -1
	if not b[0].is_valid_int() or not b[1].is_valid_int() or not b[2].is_valid_int():
		return -1
	var d0 := day_unix(int(a[0]), int(a[1]), int(a[2]))
	var d1 := day_unix(int(b[0]), int(b[1]), int(b[2]))
	return int(floor((d1 - d0) / 86400.0))

var first_day: String = ""       # 相遇日（"YYYY-MM-DD" ✓，空 = 还没记 ✓）
var last_n: int = 0              # 上次庆祝过的"第 N 天"（当天只庆一次 ✓）
var _rng := RandomNumberGenerator.new()

## 读回来；**第一次启动把今天记成相遇日** ✓（返回 true = 今天刚认下这天 ✓）
func ensure(now: Dictionary) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(FILE_PATH) == OK:
		first_day = String(cfg.get_value(SECTION, "first_day", ""))
		last_n = int(cfg.get_value(SECTION, "last_n", 0))
	if first_day == "":
		first_day = _date_key(now)
		save()
		PetLog.log("纪念日", "第一次启动 → 今天就是她遇见你的那天（%s）✓" % first_day)
		return true
	return false

## 落盘（先读回来再写，别冲掉别的 ✓）
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(FILE_PATH)
	cfg.set_value(SECTION, "first_day", first_day)
	cfg.set_value(SECTION, "last_n", last_n)
	cfg.save(FILE_PATH)

## 今天该庆祝吗？是 → {"kind": ..., "n": ...}；否 → 空 Dictionary ✓
## kind: "birthday"（周年 ✓）/ "milestone"（认识第 N 天 ✓）
func due(now: Dictionary) -> Dictionary:
	if first_day == "":
		return {}
	var today := _date_key(now)
	var days := days_between(first_day, today)
	if days <= 0:
		return {}          # 相遇当天不算（她刚出生，没什么好庆的 ✓）
	var f := first_day.split("-")
	# 周年：月/日对得上、满整整一年（按天数算，闰年也准 ✓）
	if int(now.get("month", 0)) == int(f[1]) and int(now.get("day", 0)) == int(f[2]) and days >= 365:
		var years := int(days / 365)
		if last_n != days:
			return {"kind": "birthday", "n": years, "days": days}
		return {}
	# 里程碑：认识第 N 天（当天只说一次 ✓）
	if days in MILESTONES and last_n != days:
		return {"kind": "milestone", "n": days, "days": days}
	return {}

## 这句庆祝说出口了 → 记下来（**只有真说了才记** ✓）
func mark(info: Dictionary) -> void:
	last_n = int(info.get("days", 0))

## 给模型的提示词（连得上后端时 ✓）
func prompt_for(info: Dictionary) -> String:
	if String(info.get("kind", "")) == "birthday":
		return PROMPT_BIRTHDAY % int(info.get("n", 1))
	return PROMPT_MILESTONE % int(info.get("n", 0))

## 本地台词（连不上后端时 ✓）
func local_line(info: Dictionary) -> String:
	var pool: Array = LOCAL_MILESTONE
	if String(info.get("kind", "")) == "birthday":
		pool = LOCAL_BIRTHDAY
	if pool.is_empty():
		return "……"
	return String(pool[_rng.randi_range(0, pool.size() - 1)]) % int(info.get("n", 0))

func _date_key(now: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(now.get("year", 1970)), int(now.get("month", 1)), int(now.get("day", 1))]
