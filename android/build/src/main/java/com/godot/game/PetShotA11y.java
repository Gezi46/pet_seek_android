package com.godot.game;

import android.accessibilityservice.AccessibilityService;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;

import java.util.concurrent.Executor;

/**
 * 阶段 13（2026-10-10，用户报的："每次截图都要申请权限、不够方便" ✓）：**免授权截屏**。
 *
 * 为什么需要它 ✗→✓：阶段 11 那条走 `MediaProjection` ✓，可安卓 14+ 的屏幕录制授权
 * **每次会话都得用户当面点一次** ✗（系统框 `MediaProjectionPermissionActivity` ✓，
 * 既不能记住、也不能预先授权 ✗）—— 双击一次弹一次，确实烦 ✓。
 *
 * 换的口子是 **无障碍服务** ✓：`AccessibilityService.takeScreenshot()`（API 30+ ✓）——
 * 它**只要在系统无障碍里开一次** ✓，之后随叫随截、**不再弹框** ✓✓。
 *
 * ⚠️ 两条硬性前提（都躲不掉 ✗）：
 *   ① 用户得去系统「设置 → 无障碍」把本服务**打开** ✓（我们只能拉起那个页面 ✓，
 *      开关本身必须他自己点 ✓ —— 见 PetBridge.openAccessibilitySettings ✓）；
 *   ② 安卓 **11（API 30）** 才有这个 API ✓ —— 低版本这里 `isReady()` 一律 false ✓，
 *      自动回退阶段 11 的 MediaProjection 那条 ✓（见 PetShot.request ✓）。
 *
 * 落点**故意**和阶段 11 一模一样 ✗→✓：JPEG 写进 `files/share_in.jpg`（同一套 .part 改名 ✓）、
 * 回话写 `files/shot_status.txt` 一行 ✓ —— 于是 `pet_mobile_share.gd` 那条
 * "轮询 → 解码 → 缩到 1280 → 交给她"**一个字都不用改** ✓（换入口不换链路 ✓）。
 *
 * ⚠️ 为什么这里**不用** PetShotService / 不用 moveTaskToBack ✗：
 *   无障碍截屏是"系统替我们拍" ✓，不经过任何 Activity ✓ ——
 *   既不需要安卓 14+ 那个 mediaProjection 前台服务 ✓，
 *   也不会像 `startActivityForResult` 那样把本应用整个提到前台 ✗
 *   （阶段 11 用户报的"截图截到他自己"就是那个坑 ✓，这条天然绕开 ✓✓）。
 *
 * ⚠️ 但**球自己会被拍进去** ✗（截的是整个屏幕，悬浮窗也在屏幕上 ✓）——
 *   和阶段 11 那条一样 ✓，先如实留着（她"看见"自己的球也算合理 ✓）。
 */
public class PetShotA11y extends AccessibilityService {
	private static final String TAG = "GODOT";
	/** 已连上的实例 ✓ —— 拿它才能调 takeScreenshot ✓（服务和本应用**同进程** ✓，静态字段靠得住 ✓） */
	private static PetShotA11y instance = null;
	private static final Handler ui = new Handler(Looper.getMainLooper());
	/** 回调要的执行器 ✓（结果回到主线程处理 ✓） */
	private static final Executor MAIN = new Executor() {
		@Override public void execute(Runnable r) {
			ui.post(r);
		}
	};
	/** 上一次截屏的时刻（毫秒）✓ —— 系统对"截屏间隔"有下限，太密会报 INTERVAL_TIME_SHORT ✗ */
	private static long lastShotMs = 0L;
	private static final long MIN_INTERVAL_MS = 500L;

	@Override
	protected void onServiceConnected() {
		super.onServiceConnected();
		instance = this;
		// ⚠️ 这行日志很重要 ✗：用户"以为开了、其实没开"时，只有它能分辨 ✓
		Log.i(TAG, "免授权截屏: 无障碍服务已连上 ✓（以后双击她不再弹系统授权框 ✓）");
	}

	@Override
	public void onAccessibilityEvent(AccessibilityEvent e) {
		// 我们不要任何事件 ✓ —— 只是借这个服务的"截屏"能力 ✓
	}

	@Override
	public void onInterrupt() {
		// 没实现的必要 ✓
	}

	@Override
	public boolean onUnbind(Intent intent) {
		if (instance == this) {
			instance = null;
		}
		Log.i(TAG, "免授权截屏: 无障碍服务已断开（用户关了它 ✓）");
		return super.onUnbind(intent);
	}

	@Override
	public void onDestroy() {
		if (instance == this) {
			instance = null;
		}
		super.onDestroy();
	}

	/** 现在能走无障碍截屏吗 ✓（服务已连上 + 系统够新 ✓）—— PetShot.request 靠它决定走哪条 ✓ */
	public static boolean isReady() {
		return instance != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R;
	}

	/** 请系统截一张 ✓。返回 true = 这一单接了（结果稍后写文件 ✓）；false = 这会儿接不了 ✓ */
	public static boolean capture() {
		final PetShotA11y svc = instance;
		if (svc == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return false;
		}
		// 和上一次隔太近（用户手快连点 ✓）→ 往后排一点再拍 ✓（系统会拿 INTERVAL_TIME_SHORT 拒 ✓）
		long wait = MIN_INTERVAL_MS - (System.currentTimeMillis() - lastShotMs);
		if (wait < 0) {
			wait = 0;
		}
		ui.postDelayed(new Runnable() {
			@Override public void run() {
				fire(svc, 0);
			}
		}, wait);
		return true;
	}

	private static void fire(final PetShotA11y svc, final int attempt) {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			PetShot.writeStatus(svc, "failed");
			return;
		}
		lastShotMs = System.currentTimeMillis();
		try {
			svc.takeScreenshot(Display.DEFAULT_DISPLAY, MAIN, new TakeScreenshotCallback() {
				@Override public void onSuccess(ScreenshotResult result) {
					handleSuccess(svc, result);
				}
				@Override public void onFailure(int errorCode) {
					handleFailure(svc, errorCode, attempt);
				}
			});
			Log.i(TAG, "免授权截屏: 已请系统截一张 ✓");
		} catch (Exception e) {
			Log.e(TAG, "免授权截屏: 调用 takeScreenshot 失败 " + e);
			PetShot.writeStatus(svc, "failed");
		}
	}

	private static void handleSuccess(Context c, ScreenshotResult result) {
		HardwareBuffer hb = null;
		try {
			hb = result.getHardwareBuffer();
			if (hb == null) {
				Log.e(TAG, "免授权截屏: 系统没给出图缓冲 ✗");
				PetShot.writeStatus(c, "empty");
				return;
			}
			ColorSpace cs = result.getColorSpace();
			// wrap 出来的那张是**硬件位图** ✗、且和缓冲共享内存 ✓ —— 不能直接压 JPEG ✓
			// （必须先 copy 成普通的 ARGB_8888 ✓；copy 完再关缓冲 ✓）
			Bitmap hw = Bitmap.wrapHardwareBuffer(hb, cs);
			if (hw == null) {
				Log.e(TAG, "免授权截屏: 图缓冲包不成位图 ✗");
				PetShot.writeStatus(c, "empty");
				return;
			}
			Bitmap out = hw.copy(Bitmap.Config.ARGB_8888, false);
			if (out == null) {
				Log.e(TAG, "免授权截屏: 转 ARGB_8888 失败 ✗");
				PetShot.writeStatus(c, "failed");
				return;
			}
			Log.i(TAG, "免授权截屏: 拍到一帧 " + out.getWidth() + "×" + out.getHeight() + " ✓");
			if (PetShot.writeShareIn(c, out)) {
				PetShot.writeStatus(c, "ok");
			}
			out.recycle();
		} catch (Exception e) {
			Log.e(TAG, "免授权截屏: 转图失败 " + e);
			PetShot.writeStatus(c, "failed");
		} finally {
			if (hb != null) {
				try {
					hb.close();
				} catch (Exception ignore) {
					// 关不掉就算了 ✓
				}
			}
		}
	}

	private static void handleFailure(final PetShotA11y svc, int errorCode, final int attempt) {
		Log.e(TAG, "免授权截屏: 系统拒了，错误码 " + errorCode);
		// 手太快 / 上一次还在收尾 → 等一会儿再试一次 ✓（最多 3 次 ✓）
		if (errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT && attempt < 3) {
			ui.postDelayed(new Runnable() {
				@Override public void run() {
					fire(svc, attempt + 1);
				}
			}, 600L);
			return;
		}
		// 授权被系统收了（用户在无障碍里关了它 ✓）→ 把实例清掉 ✓，
		// 于是下一次 PetShot.request 自动回退到阶段 11 的 MediaProjection 那条 ✓
		if (errorCode == ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS) {
			instance = null;
		}
		PetShot.writeStatus(svc, "failed");
	}
}