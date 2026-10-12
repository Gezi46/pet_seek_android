extends RefCounted
## 手机端"聊天记录"存储（2026-10-08 新写）。
##
## 为什么不是"把 PC 那份搬过来" ✗：**桌面端的对话记录压根不落盘** ——
## 它只是宿主里一个 `Array[String]`（`desktop_pet._chat_log`，上限 60 行，重启就没），
## 配套的 `pet_chat_panel.gd` 是"显示 + 输入"面板（而且按 330×470 + 鼠标滚轮写的，
## 手机上那套坐标和不适合），里面一次 FileAccess 都没有。所以没有可搬的存储件 ✓。
##
## 这里按 `pet_mobile_settings.gd` 的套路另写一份**纯存储**：
## 不依赖宿主、不碰 UI。坏也只坏一个文件，不会牵连她本身 ✓
##
## 落盘格式：JSON 数组，每条 `{"t": 时间戳, "who": "我"/"她"/"!", "text": "..."}`。
## 为什么不用 ConfigFile / 一行一条的纯文本：台词里**会有换行和引号**（她自己就会说长句）✗，
## 按行切会被一句多行的话搞乱；JSON 的转义交给引擎 ✓
## 文件：`user://pet_mobile_chatlog.json`（手机上是应用沙箱，和 PC 那份互不相干 ✓）

const FILE_PATH := "user://pet_mobile_chatlog.json"
## 落盘保留多少条。桌面显示上限是 60，这里**存多一点** ——
## 翻记录时"能看到更早的"才有意义 ✓（内容不大：一条几十字节，500 条也就几十 KB）
const KEEP := 500

var _items: Array = []

## 启动时读一次。文件不存在 / 内容坏了都不算错（第一次跑本来就没有 ✓）
func load_from_disk() -> void:
	_items.clear()
	if not FileAccess.file_exists(FILE_PATH):
		return
	var f := FileAccess.open(FILE_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Array:
		for row in parsed:
			if row is Dictionary and row.has("text"):
				_items.append(row)
	_prune()

## 追加并立刻落盘。⚠️ 只在"一句完整的话"上调用 ✓
## （流式回复是一段段来的，如果每段都落盘就会把同一句话切成一堆记录 ✗ ——
##  调用点在 pet_chat_flow 收尾那一处，本来就是整句 ✓）
func append(who: String, text: String) -> void:
	if text.strip_edges() == "":
		return
	_items.append({"t": int(Time.get_unix_time_from_system()), "who": who, "text": text})
	_prune()
	save()

func save() -> void:
	var f := FileAccess.open(FILE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_items))
	f.close()

## 给 UI 用：整份（按时间正序）
func all() -> Array:
	return _items

func size() -> int:
	return _items.size()

func clear() -> void:
	_items.clear()
	save()

func _prune() -> void:
	while _items.size() > KEEP:
		_items.pop_front()
