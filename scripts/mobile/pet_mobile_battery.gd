extends RefCounted
## 手机端「电量/充电关心」（2026-10-11）：她会在你没电时念叨你、充电时陪着你。
##
## 为什么值得做：这是**手机桌宠独占**的一句话 ✓ —— "你手机快没电了，早点充哦"，
## PC 桌宠永远说不出来 ✓。而且它不靠她"思考" ✓：读一次系统电量（走 PetBridge ✓），
## 到阈值就说一句，说完就闭嘴 ✓。
##
## ⚠️ 三条规矩：
##   ① **回滞**（20% 提醒、30% 才复位 ✓）—— 没有回滞的话电量在 20% 边界上抖一下
##      她就会反复念 ✗（这类"边界抖动"在传感器上吃过大亏 ✓）
##   ② **说完才记** ✓ —— 没真说出口（在忙/生闷气/被门禁挡了）就不算数，
##      下次轮询还会再试 ✓（低电量/充电状态都会持续一会儿，自然重试 ✓）
##   ③ 只在安卓上跑 ✓（别的平台没有这座桥 ✓，直接当"不知道" ✓）
##
## 这个模块**不碰 UI、不碰记忆** ✓：它只回答"现在该说句什么"（返回事件名 ✓），
## 怎么说、要不要说，归宿主（门禁/台词/落盘那一套和问候共用 ✓）。

## 电量低于这个百分比就念叨（%）
const LOW_LEVEL := 20
## 回滞：电量回到这个百分比以上（或插上电）才重置"念叨过" ✓
const RECOVER_LEVEL := 30
## 多久看一次电量（秒）。电量变化慢，1 分钟够 ✓ —— 看太勤纯属浪费 ✓
const POLL_SEC := 60.0
## 安卓 BatteryManager 的状态码（和文档一致 ✓）
const ST_CHARGING := 2
const ST_FULL := 5

## 事件名（宿主按这个挑台词 ✓）
const EV_LOW := "low"            # 电量低了、没在充 → 提醒充电
const EV_CHARGING := "charging"  # 刚插上电 → 陪一句

var _poll_in := POLL_SEC         # 距离下次看电量（秒）。开局先等一个间隔 ✓
var _low_said := false           # 这次低电量已经念叨过了 ✓
var _charge_said := false        # 这次充电已经陪过了 ✓

## 每帧调。要说话时给 {"ev": 事件名, "pct": 电量%}；没什么可说给空 Dictionary ✓。
## ⚠️ **返回了事件不等于说出口** ✓ —— 宿主说完要回一句 `mark(ev)` ✓
func tick(delta: float) -> Dictionary:
	if OS.get_name() != "Android":
		return {}
	_poll_in -= delta
	if _poll_in > 0.0:
		return {}
	_poll_in = POLL_SEC
	return _poll()

func _poll() -> Dictionary:
	var info := _read_battery()
	if info.is_empty():
		return {}          # 读不到（没 Activity / 系统没答）→ 当不知道 ✓
	var pct := int(info.get("pct", -1))
	var charging: bool = info.get("charging", false)
	# 充电状态：插上就说一句、拔掉就复位（一次充电只陪一句 ✓）
	if charging:
		if not _charge_said:
			return {"ev": EV_CHARGING, "pct": pct}
	elif _charge_said:
		_charge_said = false
	# 低电量：没在充、到阈值 → 念叨；充上了或回到 30% 以上 → 复位 ✓
	if charging or (pct >= 0 and pct > RECOVER_LEVEL):
		_low_said = false
		return {}
	if pct >= 0 and pct <= LOW_LEVEL and not _low_said:
		return {"ev": EV_LOW, "pct": pct}
	return {}

## 走桥读一次电量。安卓的桥 wrap 不出 / 抛异常 / 返回空 → 都当"不知道" ✓
func _read_battery() -> Dictionary:
	var cls = JavaClassWrapper.wrap("com.godot.game.PetBridge")
	if cls == null:
		return {}
	var s: String = String(cls.getBatteryInfo())
	var ex = JavaClassWrapper.get_exception()      # 官方要求：调完必查 ✓
	if ex != null or s.strip_edges() == "":
		return {}
	var parts := s.strip_edges().split(",")
	if parts.size() != 2:
		return {}
	return {
		"pct": int(parts[0]),
		"charging": int(parts[1]) == ST_CHARGING or int(parts[1]) == ST_FULL,
	}

## 这句真说出口了 → 记下来（**只有宿主说完才调** ✓）
func mark(ev: String) -> void:
	if ev == EV_LOW:
		_low_said = true
	elif ev == EV_CHARGING:
		_charge_said = true
