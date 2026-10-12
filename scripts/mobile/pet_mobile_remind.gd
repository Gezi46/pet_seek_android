extends RefCounted
## 提醒事项（2026-10-11，第二梯队⑧"到点喊你"）：她的小本本 ✓
##
## 一条提醒 = {id, text, due(unix 秒), done}，落 `user://pet_remind.json` ✓
## （存储路子照 pet_mobile_chatlog / pet_mobile_greet ✓，UI 归 pet_mobile_remind_ui ✓）
##
## **解析**（parse）：主人打字"提醒我十分钟后开会" → 认出时间、认出事 ✓
## 口诀：先相对（N 分钟/小时/天后 ✓）、再绝对（今天/明天/后天 + 时段 + N 点 ✓），
## **认不出就当没这事** ✓（返回空 ✓）—— 猜错时间比不记更糟 ✗。
## 为什么不上真 NLP：要认的就是"十分钟后/明天早上八点"这少数几种说法 ✓，
## 正则够覆盖；认不出时她照常回话，主人再补一句"七点"她也还能接 ✓
##
## 为什么 due 用 **unix 秒**（不是字典）：跨天比较、排序、"还有多久"都只是减法 ✓
## （墙上那套 —— 熄屏挂起墙钟照走 ✓，和 pet_mobile._away_since_unix 一个口径 ✓）

const PetLog := preload("res://scripts/sys/pet_log.gd")

## 小本本的文件（`user://pet_remind.json` ✓）。
## ⚠️ 是 **var 不是 const** ✓ —— 照 pet_memory.gd 的做法：探针要能把它指到
## 临时文件，别把真数据当实验品 ✓（改类型不影响任何调用点 ✓）
var file_path: String = "user://pet_remind.json"
## 最多留几条（完了的也占地方 —— 到点后她说一句就划掉 ✓）
const MAX_ITEMS := 50

class Item:
	var id: int = 0
	var text: String = ""
	var due: float = 0.0          # unix 秒
	var done: bool = false

	func to_dict() -> Dictionary:
		return {"id": id, "text": text, "due": due, "done": done}

	static func from_dict(d: Dictionary) -> Item:
		var it := Item.new()
		it.id = int(d.get("id", 0))
		it.text = String(d.get("text", ""))
		it.due = float(d.get("due", 0.0))
		it.done = bool(d.get("done", false))
		return it

var items: Array = []
var _next_id := 1
## 退后台时"排进前台服务那四格"的提醒 id（**只在内存里** ✓）。
## 为什么需要它：回前台对账时只该把"后台真喊过的"划掉 ✓ —— 没排上的
## （四格用完了 / 日子还远）回来还得补喊，不然她答应的事就悄没声地没了 ✗。
## 为什么不落盘：进程死了这段记忆跟着没 ✓ → 重启后自然当"没排过" ✓，
## 那些到了点的会由前台 tick 补喊 ✓（正是要的效果 ✓）
var _sched: Array = []

# ================================================================ 存取

func load() -> void:
	items.clear()
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_next_id = int((data as Dictionary).get("next_id", 1))
	for row in (data as Dictionary).get("items", []):
		if row is Dictionary:
			items.append(Item.from_dict(row))

func save() -> void:
	var arr: Array = []
	for it in items:
		arr.append((it as Item).to_dict())
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		PetLog.warn("提醒", "小本本写不进去 ✗（%s）" % file_path)
		return
	f.store_string(JSON.stringify({"next_id": _next_id, "items": arr}, "  "))
	f.close()

# ================================================================ 增删查

func add(text: String, due: float) -> Item:
	var it := Item.new()
	it.id = _next_id
	_next_id += 1
	it.text = text.strip_edges()
	it.due = due
	items.append(it)
	_trim()
	save()
	PetLog.log("提醒", "记下一条：%s（%s）" % [it.text, when_text(due)])
	return it

func remove(id: int) -> bool:
	for i in range(items.size()):
		if (items[i] as Item).id == id:
			items.remove_at(i)
			save()
			return true
	return false

func mark_done(id: int) -> void:
	for it in items:
		if (it as Item).id == id:
			(it as Item).done = true
	save()

## 到点且还没说的 ✓（前台 tick 用 ✓）
func due_open(now_ts: float) -> Array:
	var out: Array = []
	for it in items:
		var i := it as Item
		if not i.done and i.due <= now_ts:
			out.append(i)
	return out

## 退后台那会儿用的：还没说、且将在 window 秒内到点的 ✓（按到点排序 ✓）
## （她要在后台"到点喊你"，只能靠前台服务到点发通知 ✓ —— 见宿主 _start_keepalive ✓）
func due_within(window_sec: float, now_ts: float) -> Array:
	var out: Array = []
	for it in items:
		var i := it as Item
		if not i.done and i.due > now_ts and i.due <= now_ts + window_sec:
			out.append(i)
	out.sort_custom(func(a, b): return (a as Item).due < (b as Item).due)
	return out

## 回到前台时对账：把"后台排上了、而且真到了点"的标成说过了 ✓
## （在后台时服务到点就发通知喊过了 ✓ —— 回来再补一句就成复读机 ✗）。
## ⚠️ **只认 `mark_scheduled` 记下的那几条** ✓：没排上的（四格用完 / 日子还远）
## 回来由前台 tick 补喊 ✓ —— 一律划掉的话，她答应的事就悄没声地没了 ✗。
## 划完就清空名单 ✓（这次后台会话结束了 ✓）。返回划掉几条 ✓
func reconcile(now_ts: float) -> int:
	if _sched.is_empty():
		return 0
	var n := 0
	for it in items:
		var i := it as Item
		if not i.done and i.due <= now_ts and _sched.has(i.id):
			i.done = true
			n += 1
	_sched.clear()
	if n > 0:
		save()
	return n

## 记下"这次退后台排了哪几条"（宿主 `_write_nudge_lines` 调用 ✓）。
## 传空数组 = 这次一条都没排上（比如台词文件写失败 ✓）→ 回来时谁都不划 ✓
func mark_scheduled(ids: Array) -> void:
	_sched = ids.duplicate()

func count_open() -> int:
	var n := 0
	for it in items:
		if not (it as Item).done:
			n += 1
	return n

## 给 UI 的清单：没说的在前（按到点排 ✓），说过的在后 ✓
func all() -> Array:
	var open: Array = []
	var done: Array = []
	for it in items:
		if (it as Item).done:
			done.append(it)
		else:
			open.append(it)
	open.sort_custom(func(a, b): return (a as Item).due < (b as Item).due)
	done.sort_custom(func(a, b): return (a as Item).due > (b as Item).due)
	return open + done

func _trim() -> void:
	while items.size() > MAX_ITEMS:
		items.remove_at(0)          # 最老的一条（array 头部 = 最早加的 ✓）

# ================================================================ 解析

## 从主人一句话里认"提醒我…" ✓。认不出返回空 Dictionary ✓
## `now_dict` = Time.get_datetime_dict_from_system() ✓（注入是为了探针能钉死时间 ✓）
func parse(text: String, now_dict: Dictionary) -> Dictionary:
	var s := text.strip_edges()
	if s == "":
		return {}
	# 没有"提醒/叫我"这类词，就不是在安排事 ✓（免得把普通聊天当提醒 ✗）
	if s.find("提醒") < 0 and s.find("叫我") < 0:
		return {}
	var due: float = _parse_time(s, now_dict)
	if due <= 0.0:
		return {}
	var what := _parse_what(s)
	if what == "":
		return {}
	return {"text": what, "due": due}

## 认时间。认不出给 -1 ✓（调用方当"没这事" ✓）
func _parse_time(s: String, now_dict: Dictionary) -> float:
	var now_ts: float = Time.get_unix_time_from_datetime_dict(now_dict)
	# ① 相对：N 分钟/小时/天后（含"半小时后"✓、中文数词"两分钟后"✓）
	# ⚠️ 中文数词必须认 ✓ —— "两分钟后""明天早上八点"里的"八"比"2""8"更像人话 ✓
	#（\d+ 只认阿拉伯数字 ✗，这条是探针逼出来的：2026-10-11 对拍时发现的 ✓）
	var re := RegEx.new()
	# ⚠️ alternation 从左往右：长的放前面（"十二"要先匹配上 ✓）
	re.compile("(\\d+|半|两|二|三|四|五|六|七|八|九|十[一二]?|二十[一二三]?)(个)?(分钟|小时|钟头|天)后")
	var m := re.search(s)
	if m != null:
		var n := _cn_num(String(m.get_string(1)))
		var unit := String(m.get_string(3))
		if unit == "分钟":
			return now_ts + n * 60.0
		if unit == "小时" or unit == "钟头":
			return now_ts + n * 3600.0
		return now_ts + n * 86400.0        # 天
	# ② 绝对：今天/明天/后天 + 时段 + N 点(半/N分) ✓
	return _parse_clock(s, now_dict, now_ts)

## 口建制数词 → 数（"半" = 0.5 ✓；认不出给 -1 ✓）。
## 只管到得了的范围：十以内 + 十X / 二十X（时间词够用了 ✓）
func _cn_num(t: String) -> float:
	if t == "半":
		return 0.5
	if t.is_valid_float():
		return float(t)
	const DIGITS := {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
		"六": 6, "七": 7, "八": 8, "九": 9}
	if DIGITS.has(t):
		return float(DIGITS[t])
	if t.find("十") < 0:
		return -1.0
	var parts := t.split("十")            # "十二" → ["", "二"] ✓；"二十" → ["二", ""] ✓
	var tens: float = 10.0 if parts[0] == "" else float(DIGITS.get(parts[0], 0))
	var ones: float = 0.0
	if parts.size() > 1 and parts[1] != "":
		ones = float(DIGITS.get(parts[1], 0))
	return tens + ones

## 绝对时间。day_shift 天后的 h 点 m 分 ✓；认不出给 -1 ✓
func _parse_clock(s: String, now_dict: Dictionary, now_ts: float) -> float:
	var day_shift := 0
	if s.find("后天") >= 0:
		day_shift = 2
	elif s.find("明天") >= 0:
		day_shift = 1
	elif s.find("今天") >= 0 or s.find("今晚") >= 0:
		day_shift = 0
	# 时段词 → 基础小时（没有时段词时按"点"的字面意思 ✓）
	var period := -1
	if s.find("凌晨") >= 0:
		period = 0
	elif s.find("早上") >= 0 or s.find("早晨") >= 0:
		period = 6
	elif s.find("上午") >= 0:
		period = 9
	elif s.find("中午") >= 0:
		period = 12
	elif s.find("下午") >= 0:
		period = 12
	elif s.find("傍晚") >= 0:
		period = 18
	elif s.find("晚上") >= 0 or s.find("今晚") >= 0:
		period = 18
	var re := RegEx.new()
	# ⚠️ 阿拉伯 + 中文数词都认 ✓（"八点"比"8 点"像人话 ✓）；
	# alternation 从左往右，长的放前面 ✓
	re.compile("(\\d{1,2}|十[一二]?|二十[一二三]?|[一二两三四五六七八九])\\s*(?:点|:|：)\\s*(半|\\d{1,2})?")
	var m := re.search(s)
	if m == null:
		return -1.0
	var h := int(_cn_num(String(m.get_string(1))))
	if h < 0:
		return -1.0
	var min_txt := String(m.get_string(2))
	var mi := 30 if min_txt == "半" else (int(min_txt) if min_txt != "" else 0)
	# 12 小时制的口语：下午/晚上 3 点 = 15 点 ✓（12 点本身不动 ✓）
	if (period == 12 or period == 18) and h < 12:
		h += 12
	if period == 0 and h == 12:
		h = 0            # 凌晨 12 点 = 0 点 ✓
	var d := now_dict.duplicate()
	d["day"] = int(d["day"]) + day_shift
	d["hour"] = h
	d["minute"] = mi
	d["second"] = 0
	var ts: float = Time.get_unix_time_from_datetime_dict(_normalized(d))
	if ts <= now_ts:
		# 今天这点儿已经过了 → 顺延到明天 ✓（"提醒我 8 点"在 10 点说，说的是明早 8 点 ✓）
		d["day"] = int(d["day"]) + 1
		ts = Time.get_unix_time_from_datetime_dict(_normalized(d))
	return ts

## 把"日 + 了进位"的字典规整回合法值（31 号 + 1 天要进月 ✓）
func _normalized(d: Dictionary) -> Dictionary:
	var y := int(d["year"])
	var mo := int(d["month"])
	var da := int(d["day"])
	var days := _days_in_month(y, mo)
	while da > days:
		da -= days
		mo += 1
		if mo > 12:
			mo = 1
			y += 1
		days = _days_in_month(y, mo)
	return {"year": y, "month": mo, "day": da,
		"hour": int(d["hour"]), "minute": int(d["minute"]), "second": 0}

func _days_in_month(y: int, m: int) -> int:
	match m:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
	return 30

## 认"是什么事"：把时间短语和"提醒我/叫我"剔掉，剩下的就是事 ✓
func _parse_what(s: String) -> String:
	var t := s
	# 时间短语整段剔掉（"十分钟后" / "两分钟后" / "明天早上八点" ✓）
	var re1 := RegEx.new()
	# ⚠️ 和 `_parse_time` 的相对那条**同一份 alternation** ✓（认得的就要剔得掉 ✓）
	re1.compile("(\\d+|半|两|二|三|四|五|六|七|八|九|十[一二]?|二十[一二三]?)(个)?(分钟|小时|钟头|天)后")
	t = re1.sub(t, "", true)
	var re2 := RegEx.new()
	# ⚠️ 和 `_parse_clock` 那条**同一份数词 alternation** ✓ —— 认得的就要剔得掉 ✓。
	# ⚠️ 时段词是 `(...)*` 可重复 ✓ —— "明天早上八点"这种**两个词叠着说**的，
	# 写成单选的话正则会从"早上八点"处匹配（"明天"后面不是数字 ✓），
	# 把"明天"剩在事儿里 → "明天起床"✗（2026-10-11 探针逼出来的 ✓）
	re2.compile("((?:今天|明天|后天|今晚|今天晚上|早上|早晨|上午|中午|下午|傍晚|晚上|凌晨)\\s*)*"
		+ "(\\d{1,2}|十[一二]?|二十[一二三]?|[一二两三四五六七八九])\\s*(?:点|:|：)\\s*(半|\\d{1,2})?")
	t = re2.sub(t, "", true)
	# "提醒我 / 提醒 / 叫我"这些框架词 ✓
	t = t.replace("提醒我", "").replace("提醒", "").replace("叫我", "")
	t = t.replace("一下", "")
	# 标点和空白 ✓
	var re3 := RegEx.new()
	re3.compile("[，。！？、,.!?;:：；\\s]+")
	t = re3.sub(t, "", true)
	return t.strip_edges()

# ================================================================ 说出口那两句

## 走模型时的提示词（给她事实，口气她自己拿捏 ✓ —— 和 PROMPT_TOUCH 一个路子 ✓）
func prompt_for(it: Item) -> String:
	return "（你答应过主人要提醒他：%s。现在到点了。" \
		+ "用你自己的口气提醒他这一句，一两句就好，别写成通知）" % (it as Item).text

## 离线/连不上时的本地兜底 ✓（她的声音，但不现编 ✓）
func local_line(it: Item) -> String:
	return "到点啦 —— %s，别忘了哦。" % (it as Item).text

## 给人看的一眼时间："今天 15:00" / "明天 08:00" / "10-12 09:00" ✓
static func when_text(due: float) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(due))
	var hm := "%02d:%02d" % [int(dt["hour"]), int(dt["minute"])]
	var day_ts: float = Time.get_unix_time_from_datetime_dict({
		"year": int(dt["year"]), "month": int(dt["month"]), "day": int(dt["day"]),
		"hour": 0, "minute": 0, "second": 0})
	var today := Time.get_datetime_dict_from_system()
	var today_ts: float = Time.get_unix_time_from_datetime_dict({
		"year": int(today["year"]), "month": int(today["month"]), "day": int(today["day"]),
		"hour": 0, "minute": 0, "second": 0})
	var diff: float = day_ts - today_ts
	if diff <= 0.0:
		return "今天 %s" % hm
	if diff <= 86400.0:
		return "明天 %s" % hm
	if diff <= 2.0 * 86400.0:
		return "后天 %s" % hm
	return "%02d-%02d %s" % [int(dt["month"]), int(dt["day"]), hm]
