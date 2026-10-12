package com.godot.game;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;

/**
 * 阶段 11（2026-10-10，用户要的）：**双击她 → 把当前屏幕截一张给她看** ✓。
 *
 * 手机上一直缺这一角 ✗：桌面版有"偷看屏幕"（`DisplayServer.screen_get_image()` ✓），
 * 那条在移动端**没有实现** ✗（返回 null ✓）。所以手机上只能"主人挑一张给她看" ✓
 * （阶段 5c，见 pet_mobile_share.gd ✓）。这里把"主人不用挑"的那另一半补上 ✓。
 *
 * 为什么只能走 MediaProjection ✗→✓（没有第二条路）：
 *   · 想读**别的 App** 的画面就是录屏权限 ✓，安卓只开了 MediaProjection 这一个口子 ✓；
 *   · 它**必须用户当面点头** ✓（系统弹的那个"允许截屏吗"，我们既拉不起也绕不过 ✗）——
 *     这恰好是我们要的语义：截屏这件事永远得主人同意 ✓。拒绝就直接告诉她 ✓（见下面的状态文件 ✓）。
 *
 * ⚠️ 安卓 14+ 的两条硬规矩（本工程 targetSdk 36 ✓，所以两条都躲不掉 ✗）：
 *   ① 清单里要有 `FOREGROUND_SERVICE_MEDIA_PROJECTION` ✓；
 *   ② **调 `getMediaProjection` 之前**，必须已经有一个 `mediaProjection` 类型的**前台服务**在跑 ✓
 *      —— 这就是 PetShotService 存在的唯一理由 ✓（先 startForeground、再取 projection ✓，
 *         顺序反了就是 SecurityException ✗）。
 *
 * 截下来怎么送给她 ✗→✓：**复用现成那条链** ✓ ——
 *   JPEG 写进 `files/share_in.jpg`（先写 .part 再改名，和阶段 5c **同一个约定** ✓），
 *   于是 `pet_mobile_share.gd` 那条"1 秒轮询 → 解码 → 缩到 1280 → 交给她"接着干 ✓
 *   （那边**一个字都没改** ✓ —— 换入口不换链路，是这工程一直的做法 ✓）。
 *
 * 结果怎么回话 ✗→✓：那边靠"文件在不在"轮询 ✓，所以这边也用文件回话 ✓ ——
 *   写 `files/shot_status.txt` 一行（`denied` / `failed` / `empty` ✓），
 *   GDScript 读一次就吃掉 ✓（见 pet_mobile_share._check_shot_status ✓）。
 */
public class PetShot {
	private static final String TAG = "GODOT";
	/** 请求码：和 PetBridge 那个选图（0x5B01）错开 ✓ */
	public static final int REQ_CAPTURE = 0x5C01;
	/** 结果回话的文件名（= GDScript 的 `user://shot_status.txt` ✓） */
	public static final String STATUS_FILE = "shot_status.txt";
	/** 截下来的图落哪儿：**和阶段 5c 同一个文件** ✓（那条现成的发送链认的就是它 ✓） */
	public static final String OUT = "share_in.jpg";

	/** 自己存一份 Activity ✓ ——
	 *  ⚠️ 别指望"别处会给"✗：PetOverlay 就栽过这一次（自己有个 activity 字段、
	 *  没人给它设过 → 一进去就 null 返回 ✗，见 PetBridge.setActivity 的注释 ✓）。
	 *  这里**两处都设** ✓（setActivity 转发 + request 里兜一手 ✓），谁先来都行 ✓ */
	private static Activity activity = null;

	public static void setActivity(Activity a) {
		activity = a;
	}

	/** GDScript 调这个（双击她 / 双击悬浮球 ✓）：截一张屏给她看 ✓。
	 *
	 *  ⚠️ 两条路，**优先走免授权那条** ✗→✓（阶段 13，2026-10-10）：
	 *    ① 用户在系统「无障碍」里打开了 `PetShotA11y` → **直接截** ✓（不弹框、不用 Activity、
	 *       也不需要 moveTaskToBack ✓，见 PetShotA11y 头部 ✓）；
	 *    ② 没开（或系统 < 安卓 11 ✓）→ 回退阶段 11 的 MediaProjection ✓（弹一次授权框 ✓）。
	 *  两条**落点、回话完全一样** ✓（都写 `share_in.jpg` + `shot_status.txt` ✓），
	 *  所以上层（`pet_mobile_share.gd`）一个字都不用改 ✓。 */
	public static void request(Activity a) {
		if (a != null) {
			activity = a;
		}
		if (activity == null) {
			Log.e(TAG, "截屏: 还没有 Activity，授权框拉不起来");
			return;
		}
		// ① 免授权那条（无障碍）✓
		if (PetShotA11y.capture()) {
			Log.i(TAG, "截屏: 走无障碍免授权 ✓（不弹系统授权框 ✓）");
			return;
		}
		// ② 回退：MediaProjection 那条 ✓
		try {
			MediaProjectionManager mgr = (MediaProjectionManager)
					activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE);
			if (mgr == null) {
				Log.e(TAG, "截屏: 这台机器没有 MediaProjectionManager ✗");
				writeStatus(activity, "failed");
				return;
			}
			activity.startActivityForResult(mgr.createScreenCaptureIntent(), REQ_CAPTURE);
			Log.i(TAG, "截屏: 已拉起系统授权框 ✓（等用户点头 ✓）");
		} catch (Exception e) {
			Log.e(TAG, "截屏: 拉授权框失败 " + e);
			writeStatus(activity, "failed");
		}
	}

	/** GodotApp.onActivityResult 转发进来 ✓；返回 true = 这条请求归我 ✓ */
	public static boolean handleActivityResult(int requestCode, int resultCode, Intent data) {
		if (requestCode != REQ_CAPTURE) {
			return false;
		}
		if (resultCode != Activity.RESULT_OK || data == null) {
			// 用户点了"取消" ✓ —— 如实记一行，她会跟主人说一句 ✓（见 _check_shot_status ✓）
			Log.i(TAG, "截屏: 用户没点头 ✗");
			writeStatus(activity, "denied");
			return true;
		}
		// ⚠️⚠️ **先把她自己挪回后台** ✗→✓（2026-10-10 用户报的："双击后他自动弹回到程序里
		//   导致每次截图都是截他自己" ✓，日志里那两行是铁证：
		//     `startActivityForResult` 会把它**发起方所在的那个任务整个提到前台** ✓ ——
		//     我们的 Activity 在后台时一样成立 ✓，于是"双击球"顺手把她自己拉回了屏幕上 ✓，
		//     截出来的自然就是**她自己** ✓（她那句"底下那句「下次点开始我就看到了」
		//     是在跟我说话？"就是截到她自己界面的证据 ✓）。
		//   拿完授权立刻 `moveTaskToBack` ✓ → 用户原来那个 App 回到前台 ✓，
		//   服务再等一会儿才抓帧 ✓（见 PetShotService.SETTLE_MS ✓）→ 截到的就是**他真正在看的那一屏** ✓。
		//   ⚠️ **只在球浮着的时候做** ✗ —— 球浮着 = 他在别的 App 里 ✓；
		//      在 App 里双击她 = "看我这儿" ✓，那就别把她自己挪走 ✗
		if (PetOverlay.isShown() && activity != null) {
			try {
				activity.moveTaskToBack(true);
				Log.i(TAG, "截屏: 已把她自己挪回后台 ✓（你原来那个 App 该回到前面了 ✓）");
			} catch (Exception e) {
				Log.e(TAG, "截屏: moveTaskToBack 失败 " + e);
			}
		}
		// 真正去截的是服务 ✓ —— 安卓 14+ 要求"取 projection 之前"前台服务已在跑 ✓
		if (activity == null) {
			Log.e(TAG, "截屏: 拿到授权却没有 Activity ✗");
			return true;
		}
		try {
			Intent i = new Intent(activity, PetShotService.class);
			i.putExtra("resultCode", resultCode);
			i.putExtra("data", data);            // Intent 本身是 Parcelable ✓ 直接带过去 ✓
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
				activity.startForegroundService(i);
			} else {
				activity.startService(i);
			}
			Log.i(TAG, "截屏: 授权拿到 ✓ → 交给截屏服务 ✓");
		} catch (Exception e) {
			// 后台起前台服务被系统拦下是最常见的一种（安卓 12+ 起有这条限制 ✓，
			// 我们那个悬浮窗本身就是一条豁免 ✓，但拦下来也不算意外 ✓）
			Log.e(TAG, "截屏: 拉起截屏服务失败 " + e);
			writeStatus(activity, "failed");
		}
		return true;
	}

	/** 把一张位图落盘到 `files/share_in.jpg` ✓ —— 先写 .part 再改名，和阶段 5c 同一套约定 ✓。
	 *
	 *  阶段 13 抽出来的：MediaProjection 那条（PetShotService ✓）和无障碍那条（PetShotA11y ✓）
	 *  **落点必须逐字一样** ✓，所以合成一处 ✓（两边只差"怎么拿到 Bitmap" ✓）。
	 *  成功 true ✓（**ok 状态由调用方写** ✓ —— 这里只管落盘 ✓）。 */
	public static boolean writeShareIn(Context c, Bitmap b) {
		if (c == null || b == null) {
			return false;
		}
		File part = new File(c.getFilesDir(), "share_in.part");
		File done = new File(c.getFilesDir(), OUT);
		try (FileOutputStream o = new FileOutputStream(part)) {
			if (!b.compress(Bitmap.CompressFormat.JPEG, 85, o)) {
				Log.e(TAG, "截屏: 压 JPEG 失败 ✗");
				writeStatus(c, "failed");
				return false;
			}
			o.flush();
		} catch (Exception e) {
			Log.e(TAG, "截屏: 写图失败 " + e);
			writeStatus(c, "failed");
			return false;
		}
		if (done.exists() && !done.delete()) {
			Log.e(TAG, "截屏: 旧的 share_in.jpg 删不掉");
		}
		if (!part.renameTo(done)) {
			Log.e(TAG, "截屏: 改名失败 ✗");
			writeStatus(c, "failed");
			return false;
		}
		Log.i(TAG, "截屏: 已截好 " + done.length() + " 字节 → " + done.getName()
				+ "（她那边 1 秒内会自己看到 ✓）");
		return true;
	}

	/** 回话给 GDScript ✓（每次覆盖写一行 ✓；它读一次就删 ✓） */
	public static void writeStatus(Context c, String s) {
		if (c == null) {
			return;
		}
		try (FileOutputStream o = new FileOutputStream(new File(c.getFilesDir(), STATUS_FILE))) {
			o.write((s + "\n").getBytes("UTF-8"));
		} catch (Exception e) {
			Log.e(TAG, "截屏: 状态写不进去 " + e);
		}
	}
}
