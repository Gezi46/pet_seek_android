# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 手机端的设置（阶段 3 第二部分，2026-10-08）：**存哪儿、怎么读回来**。
##
## 桌面那套（右键菜单 → 设置面板 → `pet_chat.cfg`）手机上用不了：没有右键、没有键盘，
## 而且那个面板是照 330×470 的窗口画的。所以手机另存一份 `user://pet_mobile.cfg`，
## 字段少而明确 —— 只有"她自己要用的"那几项。
##
## ⚠️ **密钥不进那个 cfg**（那个文件是"能整份发给别人看"的）：明文单独写
## `user://pet_secret_mobile.dat`（应用沙箱里，不外传）。cfg 里只留一个 `has_key`，
## 导出日志时看得出"配没配"，但看不出是什么 —— 和桌面 pet_secret.gd 同一个思路。

const CONFIG_PATH := "user://pet_mobile.cfg"
const SECRET_PATH := "user://pet_secret_mobile.dat"

## 默认值 = 桌面上那套的默认（官方 API）。**别再用 127.0.0.1**：
## 手机上那个地址指的是手机自己，一定是连不上的（2026-10-08 真机日志里那条 WARN）
const DEFAULT_CHAT_URL := "https://api.deepseek.com"
const DEFAULT_CHAT_MODEL := "deepseek-flash"

var chat_url := DEFAULT_CHAT_URL
var chat_model := DEFAULT_CHAT_MODEL
var chat_access_key := ""
## 看图（摄像头）那条用哪个模型。**留空 = 关掉看图** ——
## 手机上这个模型只有一个用途：她时不时看一眼**摄像头**（截屏那条移动端没有，见宿主头部 ✓）。
## 不单配一把 key：`pet_memory_host.vision_key()` 的语义就是"没单配就复用聊天那把" ✓
var vision_model := ""
## 摸她的触感反馈（有人不喜欢震动，给个开关）
var haptic := true

# ------------------------------------------------------------------ 阶段 7（2026-10-09）：她自己开口 / 她怎么看
#
# 这四项目前在宿主里是**写死的** ✓（`_proactive_on` / `_proactive.rate` /
# `camera_every_min` / `camera_position` ✓），桌面上全都能调 ✓。手机设置页补齐它们 ✓。
# 默认值一律取桌面那份 ✓（不然同一个她，两边性格不一样 ✗）

## 她自己开口那条的总闸。桌面设置面板里能切 ✓
var proactive_on := true
## 开口频率档（0 很少 / 1 普通 / 2 频繁 / 3 很频繁）。
## ⚠️ 它只是**档位**：真正的时长在 `pet_proactive.span_for()` 里按宿主 `self_talk_after`
## （秒 ✓，出厂 300~900）缩放 ✓ —— 手机上不动那个基准，只换档 ✓
var talk_rate := 1
## 她多久自己看一眼摄像头（分钟，1~60）。桌面默认 10 ✓
var camera_every_min := 10.0
## 用哪个位置的摄像头（0 前置优先 / 1 只要前置 / 2 用后置）。
## 前置对着主人那张脸 ✓ —— 所以默认 0（挑法见 pet_peek._pick_feed ✓）
var camera_position := 0

## 档位名（设置页那个"点一下换一档"的按钮在用 ✓）。
## 和桌面 `desktop_pet.TALK_RATE_NAMES` **逐字一致** ✓ —— 同一个她，说法得一样 ✓
const RATE_NAMES: Array[String] = ["很少", "普通", "频繁", "很频繁"]
## 摄像头位置名 ✓（顺序 = camera_position 的取值 ✓）
const POS_NAMES: Array[String] = ["前置优先", "只要前置", "用后置"]

## 阶段 10（2026-10-09）：**悬浮球** ✓ —— 她浮在别的 App 上，主动说话就冒气泡 ✓。
## ⚠️ 它要一个**单独的授权**（「显示在其他应用上层」✓），勾上之后设置页会拉起系统那个页面 ✓
var overlay := false

## 读回来。**没配过是正常的**（第一次跑）——不是错误，别写日志吓人
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		chat_url = String(cfg.get_value("chat", "url", DEFAULT_CHAT_URL)).strip_edges()
		chat_model = String(cfg.get_value("chat", "model", DEFAULT_CHAT_MODEL)).strip_edges()
		vision_model = String(cfg.get_value("vision", "model", "")).strip_edges()
		haptic = bool(cfg.get_value("ui", "haptic", true))
		overlay = bool(cfg.get_value("ui", "overlay", false))
		proactive_on = bool(cfg.get_value("talk", "proactive", true))
		talk_rate = clampi(int(cfg.get_value("talk", "rate", 1)), 0, RATE_NAMES.size() - 1)
		camera_every_min = clampf(float(cfg.get_value("camera", "every_min", 10.0)), 1.0, 60.0)
		camera_position = clampi(int(cfg.get_value("camera", "position", 0)), 0, POS_NAMES.size() - 1)
	if chat_url == "":
		chat_url = DEFAULT_CHAT_URL
	if chat_model == "":
		chat_model = DEFAULT_CHAT_MODEL
	chat_access_key = _read_secret()

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)          # 先读回来，别把别的东西冲掉
	cfg.set_value("chat", "url", chat_url)
	cfg.set_value("chat", "model", chat_model)
	cfg.set_value("vision", "model", vision_model)
	cfg.set_value("ui", "haptic", haptic)
	cfg.set_value("ui", "overlay", overlay)
	cfg.set_value("talk", "proactive", proactive_on)
	cfg.set_value("talk", "rate", talk_rate)
	cfg.set_value("camera", "every_min", camera_every_min)
	cfg.set_value("camera", "position", camera_position)
	cfg.set_value("chat", "has_key", chat_access_key != "")   # 只记"有没有"，不记是什么
	cfg.save(CONFIG_PATH)
	_write_secret(chat_access_key)

## 把设置写进宿主那几个字段（宿主是弱类型引用，这里只能逐个赋）
func apply_to(host) -> void:
	host.chat_url = chat_url
	host.chat_model = chat_model
	host.chat_access_key = chat_access_key
	host.vision_model = vision_model
	host.haptic_enabled = haptic
	host.overlay_on = overlay          # 阶段 10：悬浮球（显示时机在宿主那两处 PAUSED/RESUMED ✓）
	# 阶段 7：主动说话 —— 两个门都要给（模块里是 `self_talk_enabled and _proactive_on` ✓，
	# 桌面那边一个来自检查器、一个来自面板开关；手机上就一个开关，所以两个一起写 ✓）
	host.self_talk_enabled = proactive_on
	host._proactive_on = proactive_on
	host._proactive.set_rate(talk_rate)      # 只改档位，时长口径在 pet_proactive.span_for ✓
	host.camera_every_min = camera_every_min
	host.camera_position = camera_position
	# ⚠️ 换档之后**必须重数倒计时** —— 模块头部的规矩：
	# 不重数的话，停用/旧档期间攒下的时间会在打开的一瞬间就触发 ✓
	host._proactive.reschedule()

## 给日志用的一行（**不含密钥内容**，只有长度）
func describe() -> String:
	var key_state := "没配" if chat_access_key == "" else "已配（%d 位）" % chat_access_key.length()
	var cam := "关" if vision_model.strip_edges() == "" else "%s／每 %.0f 分钟" % [
		POS_NAMES[camera_position], camera_every_min]
	return "后端 %s ｜ 模型 %s ｜ key %s ｜ 主动说话 %s（%s）｜ 看图 %s ｜ 摄像头 %s ｜ 触感 %s" % [
		chat_url, chat_model, key_state,
		"开" if proactive_on else "关", RATE_NAMES[talk_rate],
		"关" if vision_model.strip_edges() == "" else vision_model,
		cam, "开" if haptic else "关"]

func _read_secret() -> String:
	if not FileAccess.file_exists(SECRET_PATH):
		return ""
	var f := FileAccess.open(SECRET_PATH, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text().strip_edges()
	f.close()
	return s

func _write_secret(v: String) -> void:
	var s := v.strip_edges()
	if s == "":
		if FileAccess.file_exists(SECRET_PATH):
			DirAccess.remove_absolute(SECRET_PATH)
		return
	var f := FileAccess.open(SECRET_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(s)
	f.close()
