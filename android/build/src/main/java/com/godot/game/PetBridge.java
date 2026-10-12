package com.godot.game;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.BatteryManager;
import android.os.Build;
import android.provider.MediaStore;
import android.provider.Settings;
import android.util.Log;
import android.view.accessibility.AccessibilityManager;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * 阶段 5c 追加（2026-10-09）：Godot 侧 ↔ 安卓侧之间那座小桥。
 *
 * 为什么需要它：Godot 没有"拉起系统相册挑一张图"的 API ✗
 * （`DisplayServer.file_dialog_show()` 在安卓上没实现 ✓）。
 * 但 Godot 4 在安卓上有 **JavaClassWrapper** ✓ —— 它能按名字包出
 * **我们自己 classpath 里的类**、并调它的静态方法 ✓，所以这里放一个
 * 只有几个静态方法的类，GDScript 那边 wrap 一下就能用 ✓（见 pet_mobile_share.gd）。
 *
 * ⚠️ 选出来的图**走同一条落盘约定** ✓：写进 `files/share_in.jpg`
 * （= GDScript 的 `user://share_in.jpg` ✓，先写 .part 再改名 ✓）。
 * 于是"轮询 → 解码 → 缩放到 1280 → 发给她"那整条链**一个字都不用改** ✓。
 */
public class PetBridge {
	private static final String TAG = "GODOT";
	/** 请求码：自己挑一个，只要不和别人撞就行 ✓ */
	private static final int REQ_PICK_IMAGE = 0x5B01;
	/** 阶段 9b：两声"喊一声"各占一个 Job id ✓（同一个 id 会互相顶掉 ✗） */
	private static final int NUDGE_JOB_BASE = 0x9B10;

	private static Activity activity = null;

	/** GodotApp.onCreate 里调 ✓（要拿 Activity 才拉得起 startActivityForResult ✓） */
	public static void setActivity(Activity a) {
		activity = a;
		// ⚠️⚠️ 必须**转发**给悬浮球那边 ✗ —— 2026-10-09 真机踩到的坑：
		//    PetOverlay 自己也有一个 activity 字段 ✓，但没人给它设过 ✓ →
		//    `show()` 一进去就 `activity == null` 直接返回 ✗（日志里那句
		//    `E GODOT: 悬浮球: 还没有 Activity` 就是它 ✓），
		//    而 GDScript 只看"没抛异常" ✓，还乐观地打了一句"已显示 ✓" ✗。
		//    于是用户看不到球 ✓，我也看不出为什么 ✓。
		PetOverlay.setActivity(a);
		PetShot.setActivity(a);      // 阶段 11：截屏那条也要（同一个坑别再踩一次 ✗）
	}

	/** 阶段 11（2026-10-10）：双击她 → 截一张**屏幕**给她看 ✓。
	 *  阶段 13 起这一条**优先走无障碍免授权** ✓、没开才回退系统授权框 ✓（都在 PetShot.request ✓）；
	 *  MediaProjection 那条的用户点头由 GodotApp.onActivityResult 接回来 ✓。 */
	public static void takeScreenshot() {
		if (activity == null) {
			Log.e(TAG, "截屏: 还没有 Activity，拉不起授权框");
			return;
		}
		PetShot.request(activity);
	}

	/** 阶段 13（2026-10-10）：用户**在系统「无障碍」里把 `PetShotA11y` 打开了**吗 ✓
	 *  —— 打开了的话，`takeScreenshot` 随叫随截、**不再每次弹授权框** ✓。
	 *
	 *  ⚠️ 这里查的是**系统那份开关**（`AccessibilityManager` 的已启用列表 ✓），
	 *  不是"服务实例还在不在" ✗：进程万一被杀过，实例会没 ✓，
	 *  但用户的开关还在 ✓ —— 这时候该告诉他"已开启"，而不是"没开" ✓。
	 *  ⚠️ 安卓 **11（API 30）** 以下一律 false ✓ —— 那边没有这个 API ✓，
	 *  截屏自动回退到每次弹框那条 ✓（见 PetShot.request ✓）。 */
	public static boolean isA11yShotReady() {
		if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return false;
		}
		try {
			AccessibilityManager am = (AccessibilityManager)
					activity.getSystemService(Context.ACCESSIBILITY_SERVICE);
			if (am == null) {
				return false;
			}
			java.util.List<AccessibilityServiceInfo> list =
					am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK);
			String me = activity.getPackageName() + "/" + PetShotA11y.class.getName();
			for (AccessibilityServiceInfo info : list) {
				ResolveInfo ri = info.getResolveInfo();
				if (ri != null && ri.serviceInfo != null) {
					String id = ri.serviceInfo.packageName + "/" + ri.serviceInfo.name;
					if (id.equals(me)) {
						return true;
					}
				}
			}
		} catch (Exception e) {
			Log.e(TAG, "免授权截屏: 查无障碍开关失败 " + e);
		}
		return false;
	}

	/** 拉起系统那个「设置 → 无障碍」页面 ✓（设置页那个按钮调它 ✓）。
	 *  ⚠️ 我们**只能把它送到门口** ✗ —— 服务开关必须用户自己点 ✓（这是安卓的规矩 ✓）。 */
	public static void openAccessibilitySettings() {
		if (activity == null) {
			Log.e(TAG, "免授权截屏: 还没有 Activity，无障碍设置拉不起来");
			return;
		}
		try {
			Intent i = new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS);
			i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
			activity.startActivity(i);
			Log.i(TAG, "免授权截屏: 已拉起系统「无障碍」设置页 ✓");
		} catch (Exception e) {
			Log.e(TAG, "免授权截屏: 打开无障碍设置失败 " + e);
		}
	}

	/** 她这会儿**真的**在屏幕上吗 ✓（Android 的"有窗口焦点"= 用户正看着她 ✓）。
	 *  收起悬浮球之前必须问这一句 ✗ —— 真机实测：按 HOME 之后还会来一次**假的 RESUMED** ✓，
	 *  于是球刚显示 1 秒就被收掉 ✗（日志里 20:06:14 显示 → 20:06:15 收起 ✓）。 */
	public static boolean isAppVisible() {
		return activity != null && activity.hasWindowFocus();
	}

	/** GDScript 调这个：拉起系统相册 / 文件选择器 ✓ */
	public static void pickImage() {
		if (activity == null) {
			Log.e(TAG, "PetBridge: 还没有 Activity，选图拉不起来");
			return;
		}
		// 用 GET_CONTENT 而不是 ACTION_PICK：安卓 13+ 上 ACTION_PICK 走的相册很旧，
		// GET_CONTENT 会交给系统的"照片选择器 / 文件"，两种设备上都出得来 ✓
		Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
		intent.setType("image/*");
		intent.addCategory(Intent.CATEGORY_OPENABLE);
		try {
			activity.startActivityForResult(intent, REQ_PICK_IMAGE);
		} catch (Exception e) {
			Log.e(TAG, "PetBridge: 拉起选图失败 " + e);
		}
	}

	/** GodotApp.onActivityResult 转发进来 ✓；返回 true 表示"这条请求归我" ✓ */
	public static boolean handleActivityResult(int requestCode, int resultCode, Intent data) {
		if (requestCode != REQ_PICK_IMAGE) {
			return false;
		}
		if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
			Log.i(TAG, "PetBridge: 选图被取消（或没拿到数据）");
			return true;
		}
		copyToShareIn(data.getData(), "image/*（选的）");
		return true;
	}

	/** 阶段 10（2026-10-09）：悬浮球那一套 ✓（见 PetOverlay 头部说明 ✓） */
	public static void showOverlay() {
		PetOverlay.show();
	}

	public static void hideOverlay() {
		PetOverlay.hide();
	}

	/** 有没有「显示在其他应用上层」授权 ✓ */
	public static boolean canDrawOverlay() {
		return activity != null && PetOverlay.canDraw(activity);
	}

	/** 球**真的**挂上去了吗 ✓ —— GDScript 那边打完 `showOverlay()` 之后要问这一句 ✗，
	 *  否则又想当然地打"已显示 ✓"（2026-10-09 就是这么骗了自己一轮 ✓） */
	public static boolean isOverlayShown() {
		return PetOverlay.isShown();
	}

	/** 拉起系统那个授权页 ✓（用户点一下"允许"就回来了 ✓） */
	public static void requestOverlayPermission() {
		if (activity == null) {
			return;
		}
		PetOverlay.request(activity);
	}

	/** 阶段 14（2026-10-11）：**电量与充电状态** → "电量%,状态码"（如 "85,2" ✓）。
	 *
	 * 为什么要它：手机桌宠该有一句 PC 桌宠永远说不出来的话 ——
	 * "你手机快没电了，早点充哦" ✓。Godot 侧没有直接读电量的稳当路子
	 * （`OS.get_battery_level()` 各版本行为不一 ✗，充电状态干脆没有 ✓），
	 * 所以走这座桥 ✓：读一次 sticky 的 ACTION_BATTERY_CHANGED ✓，零权限 ✓。
	 *
	 * 状态码（安卓 BatteryManager 的口径 ✓，和文档一致 ✓）：
	 *   1 未知 / 2 充电中 / 3 放电中 / 4 插着但没充 / 5 已充满
	 * 取不到（没 Activity / 系统没答）给 "" —— 调用方当"不知道"跳过 ✓
	 */
	public static String getBatteryInfo() {
		if (activity == null) {
			return "";
		}
		try {
			// sticky 广播：registerReceiver(null, …) 就是"只读当前值、不真注册" ✓
			Intent battery = activity.registerReceiver(null,
					new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
			if (battery == null) {
				return "";
			}
			int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
			int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
			int status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
			int pct = (level >= 0 && scale > 0) ? Math.round(level * 100f / scale) : -1;
			return pct + "," + status;
		} catch (Exception e) {
			Log.e(TAG, "电量: 取不到 " + e);
			return "";
		}
	}

	/** 阶段 9（2026-10-09）：拉起后台保活的前台服务 ✓（她在后台还活着的前提之一，见 PetService）。
	 *
	 * ⚠️ 安卓 8+ 要用 `startForegroundService` ✗ —— 用老 API 会在
	 * "5 秒内没 startForeground" 时被系统判定为 ANR/崩溃 ✓（服务里马上就叫了 ✓）。
	 *
	 * 阶段 9b 收尾（2026-10-11）：后两个参数是**提醒事项**的到点延时 ✓（0 = 没有 ✓）——
	 * 四个延时一起交给服务 `postDelayed` ✓，到点各消耗台词文件里的一行 ✓
	 * （台词由 GDScript 按时间顺序整份写好 ✓，所以"第几行对第几个延时"天然对齐 ✓）。
	 * ⚠️ 提醒只占后两格 ✓ —— 她主动"喊一声"那两格的优先级不变 ✓（那是她的性子 ✓）。
	 */
	public static void startKeepAlive(long nudge0Ms, long nudge1Ms,
			long remind0Ms, long remind1Ms) {
		if (activity == null) {
			Log.e(TAG, "保活: 还没有 Activity，服务拉不起来");
			return;
		}
		try {
			Intent i = new Intent(activity, PetService.class);
			// 阶段 9c：两句"喊一声"的延时一起带进去 ✓ 由服务自己 postDelayed ✓
			//（系统调度器在国产 ROM 上会被压住 ✓，服务自己计时才靠得住 ✓）
			i.putExtra("nudge0_ms", nudge0Ms);
			i.putExtra("nudge1_ms", nudge1Ms);
			// 阶段 9b 收尾：提醒事项的到点 ✓（0 = 这一格空着 ✓）
			i.putExtra("remind0_ms", remind0Ms);
			i.putExtra("remind1_ms", remind1Ms);
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
				activity.startForegroundService(i);
			} else {
				activity.startService(i);
			}
		} catch (Exception e) {
			Log.e(TAG, "保活: 拉起服务失败 " + e);
		}
	}

	/** 回到前台就收掉 ✓ —— 不留常驻通知（下次退后台再拉 ✓） */
	public static void stopKeepAlive() {
		if (activity == null) {
			return;
		}
		try {
			activity.stopService(new Intent(activity, PetService.class));
		} catch (Exception e) {
			Log.e(TAG, "保活: 停服务失败 " + e);
		}
	}

	/** 阶段 9b：安排一次"她喊你一声"的闹钟（delayMs 毫秒后 ✓）。
	 *
	 * ⚠️ 用的是 **inexact** 的 `setAndAllowWhileIdle` ✗ 不是 `setExact...`：
	 * 精确闹钟在安卓 12+ 要用户另外授权（`SCHEDULE_EXACT_ALARM` ✓），
	 * 而"她过一会儿喊你一声"本来就不需要卡到秒 ✓ —— 不值得为此多要一个权限 ✓。
	 */
	public static void scheduleNudge(long delayMs, int index) {
		if (activity == null) {
			Log.e(TAG, "喊一声: 还没有 Activity");
			return;
		}
		try {
			// ⚠️ 用 **JobScheduler** 不是 AlarmManager ✗ —— 详见 PetNudgeJobService 头部：
			//    后台应用会被 app freezer 冻住 ✓，而被冻结的应用**它的闹钟不会被投递** ✗
			//    （真机实测 Reason=frozen ✓）；Job 则会把冻结的应用唤醒 ✓✓
			android.app.job.JobScheduler js = (android.app.job.JobScheduler)
					activity.getSystemService(android.content.Context.JOB_SCHEDULER_SERVICE);
			if (js == null) {
				Log.e(TAG, "喊一声: 没有 JobScheduler");
				return;
			}
			long d = Math.max(5000L, delayMs);
			android.content.ComponentName cn =
					new android.content.ComponentName(activity, PetNudgeJobService.class);
			android.app.job.JobInfo job = new android.app.job.JobInfo.Builder(NUDGE_JOB_BASE + index, cn)
					.setMinimumLatency(d)
					.setOverrideDeadline(d + 60000L)     // 最迟 +1 分钟一定跑 ✓（她喊你不必卡到秒 ✓）
					.build();
			js.schedule(job);
			Log.i(TAG, "喊一声: 已排 Job #" + index + "（" + (delayMs / 1000) + " 秒后，最迟 +60 秒）");
		} catch (Exception e) {
			Log.e(TAG, "喊一声: 排 Job 失败 " + e);
		}
	}

	/** 回前台：把还没到点的 Job 全撤掉 ✓（不撤的话你刚回来她还追着喊 ✗） */
	public static void cancelNudges() {
		if (activity == null) {
			return;
		}
		try {
			android.app.job.JobScheduler js = (android.app.job.JobScheduler)
					activity.getSystemService(android.content.Context.JOB_SCHEDULER_SERVICE);
			if (js != null) {
				js.cancelAll();          // 只撤本应用的 Job ✓（这个 App 的 Job 全是"喊一声" ✓）
				Log.i(TAG, "喊一声: 已撤销所有 Job");
			}
		} catch (Exception e) {
			Log.e(TAG, "喊一声: 撤销失败 " + e);
		}
	}

	/** 阶段 9b 收尾（2026-10-11）：**电池优化白名单** —— "让她一直在"的第二道保险 ✓
	 *
	 * 为什么是"第二道"：前台服务已经能按住进程 ✓（app freezer 那件事就那么解的 ✓），
	 * 但国产 ROM 的省电策略还是会把后台应用顺手按进一堆限制里 ✓（真机日志里见过 ✓）。
	 * 进白名单是用户能替她做的最彻底的一件事 ✓ —— 所以定位是**双保险**，不是必须 ✓。
	 *
	 * ⚠️ 走 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`（带 `package:` 的 Uri ✓）：
	 *    系统直接弹一个"允许忽略电池优化吗"的对话框 ✓，用户点一下"允许"就成了 ✓
	 *    —— 不用把人丢进设置里翻七八层 ✗（那条路是 `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` ✓）。
	 * ⚠️ 要 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 权限 ✓
	 *    （普通权限，装的时候就给 ✓，写在 standard 源集的清单里 ✓）。
	 */
	public static boolean isIgnoringBatteryOptimizations() {
		if (activity == null) {
			return false;
		}
		try {
			android.os.PowerManager pm = (android.os.PowerManager)
					activity.getSystemService(Context.POWER_SERVICE);
			return pm != null && pm.isIgnoringBatteryOptimizations(activity.getPackageName());
		} catch (Exception e) {
			Log.e(TAG, "电池白名单: 查不了 " + e);
			return false;
		}
	}

	/** 拉起系统那个"允许忽略电池优化吗"对话框 ✓ */
	public static void requestIgnoreBatteryOptimizations() {
		if (activity == null) {
			Log.e(TAG, "电池白名单: 还没有 Activity，对话框拉不起来");
			return;
		}
		try {
			Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
			i.setData(Uri.parse("package:" + activity.getPackageName()));
			i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
			activity.startActivity(i);
			Log.i(TAG, "电池白名单: 已拉起系统对话框 ✓");
		} catch (Exception e) {
			Log.e(TAG, "电池白名单: 拉不起对话框 " + e);
		}
	}

	/** 阶段⑤（2026-10-11）：桌面小组件该刷新了 ✓ —— GDScript 每听她说一句就调 ✓
	 *  （见 PetWidget.java：那边读 `files/widget_line.txt` 重新渲染 ✓）。
	 *  ⚠️ 句子本身**不走这个参数** ✗：走文件 ✓（理由见 PetWidget 类头上那段 ✓）。 */
	public static void refreshWidget() {
		if (activity == null) {
			// 只可能是"App 都没起来"✓ —— 那时她说的话也无从更新 ✓，安静返回 ✓
			Log.w(TAG, "小组件: 还没有 Activity，没什么好刷的");
			return;
		}
		PetWidget.refreshWidget(activity);
	}

	/** 把导出好的日志包放进**公共「下载」**里，成功返回"下载/文件名"，失败返回空串。
	 *
	 * 为什么不能让 GDScript 自己写 ✗：安卓 10+ 的公共目录必须经 MediaStore 才写得进去 ✓；
	 * 而 `user://` 在应用沙箱里、用户根本拿不到 ✗，
	 * `/sdcard/Android/data/<包名>/` 从 USB 看又多半是空的（11+ 的限制 ✗）。
	 * 「下载」是唯一一处用户随手就找得到、又能转发出去的地方 ✓。
	 */
	public static String saveToDownloads(String srcPath, String displayName) {
		if (activity == null || srcPath == null || displayName == null) {
			return "";
		}
		File src = new File(srcPath);
		if (!src.exists()) {
			Log.e(TAG, "导出: 源文件不在 " + srcPath);
			return "";
		}
		Uri uri = null;
		try {
			ContentValues cv = new ContentValues();
			cv.put(MediaStore.Downloads.DISPLAY_NAME, displayName);
			cv.put(MediaStore.Downloads.MIME_TYPE, "application/zip");
			// IS_PENDING：先占位、写完再放出来 ✓ —— 否则用户在写一半时点开就是个坏包 ✗
			cv.put(MediaStore.Downloads.IS_PENDING, 1);
			uri = activity.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
			if (uri == null) {
				Log.e(TAG, "导出: MediaStore 没给出 URI");
				return "";
			}
			try (InputStream in = new FileInputStream(src);
					OutputStream out = activity.getContentResolver().openOutputStream(uri)) {
				if (out == null) {
					Log.e(TAG, "导出: 拿不到输出流");
					return "";
				}
				byte[] buf = new byte[64 * 1024];
				int n;
				while ((n = in.read(buf)) > 0) {
					out.write(buf, 0, n);
				}
				out.flush();
			}
			ContentValues done = new ContentValues();
			done.put(MediaStore.Downloads.IS_PENDING, 0);
			activity.getContentResolver().update(uri, done, null, null);
			Log.i(TAG, "导出: 已放进「下载」 " + displayName + "（" + src.length() + " 字节）");
			return "下载/" + displayName;
		} catch (Exception e) {
			Log.e(TAG, "导出: 写进「下载」失败 " + e);
			if (uri != null) {
				try {
					activity.getContentResolver().delete(uri, null, null);
				} catch (Exception ignore) {
					// 删不掉就算了，留着也是个 IS_PENDING 的坏条目 ✓
				}
			}
			return "";
		}
	}

	/** 把 content:// 的字节复制进 files/share_in.jpg ✓
	 *  先写 .part 再改名：否则她可能读到**写了一半**的图 ✗（大图要几百毫秒 ✓） */
	public static void copyToShareIn(Uri uri, String type) {
		if (activity == null || uri == null) {
			Log.e(TAG, "share_in: 没有 Activity 或 URI，复制不了");
			return;
		}
		File part = new File(activity.getFilesDir(), "share_in.part");
		File done = new File(activity.getFilesDir(), "share_in.jpg");
		try (InputStream in = activity.getContentResolver().openInputStream(uri);
				FileOutputStream out = new FileOutputStream(part)) {
			if (in == null) {
				return;
			}
			byte[] buf = new byte[64 * 1024];
			int n;
			while ((n = in.read(buf)) > 0) {
				out.write(buf, 0, n);
			}
			out.flush();
		} catch (Exception e) {
			Log.e(TAG, "share_in: 复制图片失败 " + e);
			return;
		}
		if (done.exists() && !done.delete()) {
			Log.e(TAG, "share_in: 旧的 share_in.jpg 删不掉");
		}
		if (!part.renameTo(done)) {
			Log.e(TAG, "share_in: 改名失败");
			return;
		}
		Log.i(TAG, "share_in: 收到一张图 " + done.length() + " 字节（" + type + "）");
	}
}
