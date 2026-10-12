extends RefCounted
## 系统分享收图（阶段 5c，2026-10-09）：主人在相册/浏览器里点「分享」→ 选她 → 她看图说话。
##
## 为什么要有这条：手机上**没有截屏那条** ✗（`DisplayServer.screen_get_image()` 在移动端
## 没有实现、返回 null ✓）—— 桌面版"偷看屏幕"占的那个位置，手机上由
## **"主人主动把图给她看"** 补上 ✓✓（比偷看还诚实：图是主人挑的 ✓）。
##
## ⚠️ 阶段 11（2026-10-10）把**另一半**也补上了 ✓：**双击她 = 截一张屏给她看** ✓
## （走 `MediaProjection` ✓，见 PetShot.java 头部 ✓）。
## ⚠️ 阶段 13（2026-10-10）：截屏**又多了一条入口** —— 无障碍免授权（`PetShotA11y` ✓，
## 见 pet_mobile.gd 头部第 13 条 ✓）。两条入口**落点逐字一样** ✓，所以本文件照旧**一个字都不用改** ✓。
## 落点**故意**和上面同一条 ✗：
## 截下来的 JPEG 写进**同一个** `share_in.jpg` ✓ —— 于是这里**一个字都不用改** ✓，
## 下面那条轮询照样在 1 秒内把它交给她 ✓（换入口不换链路 ✓）。
## 唯一的新东西是"回话"：Java 那边把结果写一行 `shot_status.txt` ✓，
## 由 `_check_shot_status` 念给她听 ✓（她被拒绝 / 没截到时也该有句话 ✓）。
##
## 链路三段，各管一件事：
##   ① 安卓那侧（`android/build/src/main/java/com/godot/game/GodotApp.java`）：
##      收到 `ACTION_SEND` 的图片 → 字节写进 `files/share_in.jpg`（就是这里的 `user://share_in.jpg` ✓）。
##      它先写 `.part` 再改名 ✓，所以这里**看不到写了一半的图** ✓。
##   ② 这里：每秒轮询一次 → 有图就**解码 → 缩到 1280 以内 → 压 JPEG → data URL** ✓
##   ③ 走**和摄像头完全相同**的那条发送链（`_send_first` ✓）：共用客户端 / 气泡 / 记忆 ✓
##
## 门禁（和摄像头那条一个口径 ✓）：
##   她在忙 → 把图放回去，下一秒再试 ✓（别丢掉主人给的东西 ✗）
##   没配看图模型 → 说一句，然后把图吃掉 ✓（不然它会一直躺在那儿、每次都触发一遍 ✗）
##
## 对宿主的接口面（只列真正用到的）：
##   host._vision_ready() / host._ai_busy() / host._send_first(prompt, image)
##   host._begin_stream_bubble() / host._say() / host._last_origin / host._chat_streaming

## 安卓那侧落盘的位置（先写 share_in.part ✓ 写完才改名成这个 ✓）
const FILE := "user://share_in.jpg"
## 阶段 11：截屏那条的"回话"文件 ✓（Java 写一行 ✓，这里读一次就吃掉 ✓）
const SHOT_STATUS := "user://shot_status.txt"
## 轮询间隔（秒）。分享过来的图一般几百 KB ✓，解码+缩放也就几十毫秒 ✓，1 秒够快也不费 ✓
const POLL_SEC := 1.0
## 发给模型前的最大边：**必须缩** —— 相册里的原图动辄 4000×3000，
## base64 之后十几 MB，后端和模型都吃不消 ✗（和摄像头那条同样压到 1280 以内 ✓）
const MAX_W := 1280

## 递给她时用的那句话。两层要求：
##   ① **别当"看图描述"来做** ✗（2026-10-09 用户反馈："感觉他在仔细描述每一张图，有点假" ✓）：
##      要的是"她看了一眼、随口接一句" ✓ —— 挑一处她真在意的说，别一件件报画面里有什么 ✓
##   ② 但**只讲真看到的**这条不能松 ✗：看不清/空图就直说，别猜别编 ✓
##      （图还在时她会照着想象编 ✓，见 pet_peek.gd 头部第 ⑥ 条）；图可能是黑白的，
##      那就别提颜色 ✓
const PROMPT_SHARE := "（主人给你看了这张图。别当成「描述图片」的任务来做 —— " \
	+ "像朋友随手发你一张图、你顺口接一句那样，挑你真注意到的一两处说，口气照你平时的来。" \
	+ "别一件件报画面里有什么，也别写成解说。看不清、或者图是空白的就直说看不清，别猜别编。" \
	+ "另外这图可能是黑白的，那就别聊颜色）"

var _host = null
var _acc := 0.0


func setup(host) -> void:
	_host = host


func tick(delta: float) -> void:
	_acc += delta
	if _acc < POLL_SEC:
		return
	_acc = 0.0
	_check_shot_status()          # 阶段 11：先听 Java 那边有没有话要说 ✓
	if not FileAccess.file_exists(FILE):
		return
	# ⚠️ 先**认领**这张图（改名成 .taken ✓）：后面解码 / 发送都可能失败、或者要等下一秒，
	# 不改名的话下一次轮询会读到同一张、重复发一遍 ✗（想清楚才这么写的 ✓）
	var taken := FILE + ".taken"
	DirAccess.remove_absolute(taken)
	if DirAccess.rename_absolute(FILE, taken) != OK:
		return
	_handle(taken)


func _handle(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := _decode(bytes)
	if img == null or img.is_empty():
		DirAccess.remove_absolute(path)
		_host._say("这张图我打不开诶…换个格式再试试？")
		return
	if not _host._vision_ready():
		DirAccess.remove_absolute(path)
		_host._say("我这边还没配好看图的模型呢…")
		return
	if _host._ai_busy():
		# 她在忙：**把图放回去** ✓ 下一秒再试（别把主人给的东西吃掉 ✗）
		DirAccess.rename_absolute(path, FILE)
		return
	if img.get_width() > MAX_W:
		var r := float(MAX_W) / float(img.get_width())
		img.resize(MAX_W, maxi(1, int(img.get_height() * r)), Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(0.8)
	if jpg.is_empty():
		DirAccess.remove_absolute(path)
		_host._say("这张图我压不动诶…")
		return
	DirAccess.remove_absolute(path)          # 吃掉了 ✓（别让它在私有目录里越积越多 ✓）
	_host._begin_stream_bubble()
	_host._last_origin = "share"
	if not _host._send_first(PROMPT_SHARE,
			"data:image/jpeg;base64," + Marshalls.raw_to_base64(jpg)):
		_host._chat_streaming = false
		_host._say("发送失败，稍后再试～")


# ------------------------------------------------------------------ 应用内选图（2026-10-09 追加）

## "从相册挑一张给她"：拉起系统选图器 ✓
##
## 链路：这里用 **JavaClassWrapper** 调 `PetBridge.pickImage()` ✓
##   → 系统选图器 → `GodotApp.onActivityResult` → `PetBridge` 把它复制成
##     `files/share_in.jpg` ✓ → **本模块的轮询接管** ✓
##   （也就是说：这条和"从别处分享进来"走的是**同一条**后半段 ✓，一个字都不用改 ✓）
##
## ⚠️ JavaClassWrapper 的三条规矩（官方文档明写的）：
##   ① 只在 Android 上能用 ✓ —— 别的平台 `wrap()` 返回**空类** ✗，所以必须先判平台 ✓
##   ② 调完**必须查 `get_exception()`** ✓ —— 不然 Java 那边的异常会被静静吞掉 ✗
##   ③ 类名/方法名要和 Java 侧**逐字一致** ✓（见 android/build/src/main/java/com/godot/game/PetBridge.java）
func pick_from_gallery() -> bool:
	if OS.get_name() != "Android":
		_host._say("我这边没有相册诶…你直接从相册分享给我也一样的 ✓")
		return false
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		_host._say("选图这条我这边没接上诶…")
		return false
	cls.pickImage()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		push_warning("[分享] 调 PetBridge.pickImage 抛异常：%s" % str(ex))
		_host._say("相册没打开诶…你直接在相册里分享给我吧")
		return false
	if OS.is_debug_build():
		print("[PetDeek] 分享：已拉起系统选图器 ✓")
	return true


# ------------------------------------------------------------------ 截屏给她看（阶段 11，2026-10-10）

## **双击她 → 截一张屏给她看** ✓（桌面上"偷看屏幕"那一角，手机上在这儿补上 ✓）
##
## 为什么这条只能交给 Java 干 ✗：读**别的 App** 的画面就是录屏权限 ✓，
## 安卓只开了 `MediaProjection` 这一个口子 ✓，而且**必须弹出系统那个"允许截屏吗"** ✓ ——
## GDScript 这侧既拿不到屏幕、也弹不出那个框 ✓。
## 所以这里只做一件事：请 Java 去拉授权框 ✓；后面（授权 → 截 → 落盘 → 回话）
## 全在 PetShot / PetShotService 里 ✓。
##
## ⚠️ 截下来的图**不用这里再接一次** ✓ —— 它落的就是上面那个 `share_in.jpg` ✓，
## 下一秒的 tick 会照常把她叫醒 ✓（这边只多听一句回话 ✓，见 _check_shot_status ✓）
func take_screenshot() -> bool:
	if OS.get_name() != "Android":
		_host._say("截屏这条只有手机上才有诶…")
		return false
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		_host._say("截屏这条我这边没接上诶…")
		return false
	cls.takeScreenshot()
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		push_warning("[截屏] 调 PetBridge.takeScreenshot 抛异常：%s" % str(ex))
		_host._say("截屏没拉起来诶…")
		return false
	return true


## 念 Java 那边留下的那句回话 ✓（`shot_status.txt` ✓，见 PetShot.writeStatus ✓）
## ⚠️ 每条**只念一次** ✗：读完就删 ✓（不删的话每秒轮询都会再念一遍 ✓）。
## 成功的那个（"ok"）**不念** ✓ —— 图已经在 share_in.jpg 里了 ✓，
## 下一秒她会自己对着图说话 ✓，再来一句"截好了"只会吵 ✗
func _check_shot_status() -> void:
	if not FileAccess.file_exists(SHOT_STATUS):
		return
	var f := FileAccess.open(SHOT_STATUS, FileAccess.READ)
	if f == null:
		return
	var s := f.get_as_text().strip_edges()
	f.close()
	DirAccess.remove_absolute(SHOT_STATUS)
	match s:
		"ok":
			if OS.is_debug_build():
				print("[PetDeek] 截屏：图上路了 ✓（交给 share_in 那条链 ✓）")
		"denied":
			_host._say("你没让我看诶…下次点「开始」我就看到了 ✓")
		"empty":
			_host._say("屏幕我一眼都没看着…这台手机把它拦下来了 ✓")
		_:
			_host._say("截屏没成诶…")


## 按**魔数**选解码器 —— 安卓分享过来的可能是 jpg / png / webp，
## 而 Godot 4 没有"自动认格式"的 Image 加载函数 ✗（load_*_from_buffer 各管一种 ✓），
## 所以自己看一眼开头几个字节 ✓
func _decode(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() > 3 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() > 8 and bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() > 12 and bytes[0] == 0x52 and bytes[8] == 0x57:   # RIFF....WEBP
		err = img.load_webp_from_buffer(bytes)
	if err != OK:
		return null
	return img
