extends RefCounted
## 手机端「时段问候」（2026-10-11）：早上说早安、饭点问吃饭、夜深了催睡觉。
##
## 为什么值得单独一块：她以前的开口全靠**随机倒计时**（pet_proactive ✓）——
## 什么时候说话全看运气，没有"时段"这个概念 ✗。而陪伴感很大一块来自
## "她知道现在是什么时候" ✓：早上打开她说声早、饭点问句吃了没、深夜催你睡觉，
## 这三句比十句随机搭话都更像"陪着你" ✓。
##
## 和主动说话那条的分工：pet_proactive 管"闲得慌随便聊聊" ✓，
## 这里管"到这个点儿该说的那句话" ✓ —— 一天最多四句（早/午/晚/深夜各一次 ✓），
## 多一句就成骚扰 ✗。每个时段**当天只说一次**（落盘记着 ✓，重启不重复 ✓）。
##
## 内容分两条路（和「欢迎回来」同一个规矩 ✓）：
##   · 连得上后端 → 给模型一个"现在几点 + 该干什么"的事实，口气她自己拿捏 ✓
##   · 连不上 → 本地台词兜底 ✓（问候不该反过来依赖联网 ✗）
##
## 落盘：`user://pet_greet.cfg`，一个时段一个键，值是那天日期字符串 ✓
## （`{"greet": {"morning": "2026-10-11", ...}}` ✓）。文件不在 = 没打过招呼 ✓，不是错 ✓

const FILE_PATH := "user://pet_greet.cfg"
const SECTION := "greet"

## 时段名（设置/日志/探针都用这套 ✓）。空串 = 现在不在任何时段里 ✓
const SLOT_MORNING := "morning"     # 05:00–10:59 早安
const SLOT_NOON := "noon"           # 11:00–13:29 问午饭
const SLOT_DINNER := "dinner"       # 17:00–19:29 问晚饭
const SLOT_NIGHT := "night"         # 23:00–04:59 催睡觉

## 每个时段的提示词：**只给事实**（现在几点、该干什么），口气归她 ✓
## （和 PROMPT_TOUCH / PROMPT_BACK 一个路子 —— 写死语气就千人一面了 ✗）
const PROMPTS := {
	SLOT_MORNING: "（现在是早上，主人刚打开你。用你自己的口气跟他道个早安，一两句就好，"
		+ "可以顺口问问他吃早饭了没）",
	SLOT_NOON: "（现在快到中午了。用你自己的口气问问他吃饭了没有，一两句就好，别写成汇报）",
	SLOT_DINNER: "（现在是傍晚，正是吃晚饭的时候。用你自己的口气提醒他去吃点东西，"
		+ "一两句就好，可以关心他别凑合）",
	SLOT_NIGHT: "（现在夜深了。用你自己的口气催他睡觉，一两句就好。"
		+ "可以撒娇着凶他，但别真的长篇大论）",
}

## 连不上后端时的本地台词（每个时段几句 ✓）。她离线也该会道早安 ✓
const LOCAL_LINES := {
	SLOT_MORNING: ["早呀。今天也要好好吃饭。", "起来啦？我等你一会儿了。", "早安——昨晚睡得怎么样？"],
	SLOT_NOON: ["午饭时间到啦，去吃点东西？", "这个点，该吃午饭了吧。", "别忙忘了吃饭呀。"],
	SLOT_DINNER: ["晚饭点啦，歇会儿吃点东西吧。", "晚上要吃好一点哦。", "该吃晚饭了，别凑合。"],
	SLOT_NIGHT: ["这么晚了，该睡啦。", "夜深了，明天还要早起呢。", "再不睡我可要生气了哦。早点休息。"],
}

## 小时 → 时段（**纯函数**，探针直接验 ✓）。不在任何时段里就给空串 ✓
static func slot_of(hour: int) -> String:
	if hour >= 23 or hour < 5:
		return SLOT_NIGHT
	if hour < 11:
		return SLOT_MORNING
	if hour < 14:
		return SLOT_NOON
	if hour >= 17 and hour < 20:
		return SLOT_DINNER
	return ""

## 今天几号（"2026-10-11" 这种 ✓）—— 键就用它，跨天自然失效 ✓
static func date_key(now: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(now.get("year", 1970)), int(now.get("month", 1)), int(now.get("day", 1))]

var _rng := RandomNumberGenerator.new()
## 时段 → 上次打招呼那天的日期键（内存这份 ✓；落盘见 load/save ✓）
var _last: Dictionary = {}

func _init() -> void:
	_rng.randomize()

## 读回来。没配过 / 文件坏了都不算错（第一次跑本来就没有 ✓）
func load() -> void:
	_last.clear()
	var cfg := ConfigFile.new()
	if cfg.load(FILE_PATH) != OK:
		return
	for slot in PROMPTS.keys():
		var v: Variant = cfg.get_value(SECTION, String(slot), "")
		if String(v) != "":
			_last[String(slot)] = String(v)

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(FILE_PATH)          # 先读回来，别把别的东西冲掉
	for slot in _last.keys():
		cfg.set_value(SECTION, String(slot), String(_last[slot]))
	cfg.save(FILE_PATH)

## 现在这个时段**今天还没打过招呼**吗？是 → 给时段名；否 / 不在时段里 → 空串 ✓
## ⚠️ 调用时机是"准备说之前"（不是在排班的时候 ✓）—— 用户要是聊了半小时，
## 时段都可能已经过了，那时候再问一次才准确 ✓
func due(now: Dictionary) -> String:
	var slot := slot_of(int(now.get("hour", 0)))
	if slot == "":
		return ""
	if String(_last.get(slot, "")) == date_key(now):
		return ""
	return slot

## 这句打招呼已经说出口了 → 记下来（**只有真说了才记** ✓）
func mark(slot: String, now: Dictionary) -> void:
	_last[slot] = date_key(now)

## 给模型的提示词（连得上后端时走这条 ✓）
func prompt_for(slot: String) -> String:
	return String(PROMPTS.get(slot, "（用你自己的口气跟主人打个招呼，一两句就好）"))

## 本地台词（连不上后端时走这条 ✓）
func local_line(slot: String) -> String:
	var pool: Array = LOCAL_LINES.get(slot, [])
	if pool.is_empty():
		return "……"
	return String(pool[_rng.randi_range(0, pool.size() - 1)])
