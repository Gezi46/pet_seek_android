package com.godot.game;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;

import java.nio.ByteBuffer;

/**
 * 阶段 11（2026-10-10）：**截一次屏**的那个前台服务 ✓（头部说明见 PetShot.java ✓）。
 *
 * 它只为一个理由存在 ✗：安卓 14+ 规定"调 `getMediaProjection()` 之前，必须已经有一个
 * `mediaProjection` 类型的前台服务在跑" ✓ —— 所以顺序**只能**是：
 *   ① 先 startForeground（带 mediaProjection 类型 ✓）
 *   ② 再 getMediaProjection ✓
 *   ③ 建 VirtualDisplay + ImageReader → 读到**一帧**就收工 ✓
 * 反了就是 SecurityException ✗（而且是在用户点完"允许"之后才炸 ✗，特别难查 ✓）。
 *
 * 它**活得极短** ✓（正常情况下不到一秒：通知都来不及被看清 ✓）：
 * 截到一帧 → 写好 share_in.jpg → release 掉 VirtualDisplay / projection → stopSelf ✓。
 * ⚠️ 一定要 release + stop ✓：投影不放掉的话，状态栏会**一直挂着投屏图标** ✗
 * （那是"她还在看你屏幕"的意思 ✓，我们只看一眼 ✓）。
 *
 * 为什么要"给个期限"✗：万一这一帧迟迟不来（某些 ROM 上 VirtualDisplay 首帧会慢 ✓），
 * 不能把一条前台服务挂在那儿 ✓ —— 6 秒还不来就认输、如实回一句 `empty` ✓（见 PetShot.writeStatus ✓）。
 */
public class PetShotService extends Service {
	private static final String TAG = "GODOT";
	private static final String CHANNEL_ID = "pet_shot";
	private static final int NOTI_ID = 0x9F01;
	/** 等帧的上限（毫秒）✓（到点认输，别把服务挂着 ✗） */
	private static final long GIVE_UP_MS = 6000L;
	/** 抓帧前先等画面**落定**（毫秒 ✓）—— 见下面"不挂 onImageAvailable"那段说明 ✓ */
	private static final long SETTLE_MS = 700L;

	private final Handler ui = new Handler(Looper.getMainLooper());
	private MediaProjection projection = null;
	private VirtualDisplay display = null;
	private ImageReader reader = null;
	/** 只认**第一帧** ✓（后面再来帧就当没看见 ✓ —— 别写第二遍 ✗） */
	private boolean done = false;

	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		int code = (intent == null) ? Activity.RESULT_CANCELED
				: intent.getIntExtra("resultCode", Activity.RESULT_CANCELED);
		Intent data = (intent == null) ? null
				: (Intent) intent.getParcelableExtra("data");

		// ① 先起前台 ✓（安卓 14+ 的硬规矩，见类头 ✓）——
		//    通知里直说我们在干什么 ✓：前台服务就必须让人看得见，这是安卓的规矩 ✓，
		//    而且"她要看一眼屏幕"这件事本来就该让主人知道 ✓
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			NotificationManager nm =
					(NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
			if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
				NotificationChannel ch = new NotificationChannel(
						CHANNEL_ID, "她看一眼你的屏幕", NotificationManager.IMPORTANCE_MIN);
				ch.setDescription("只在你说「看吧」之后闪一下，截完立刻收掉");
				ch.setShowBadge(false);
				nm.createNotificationChannel(ch);
			}
		}
		Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
				? new Notification.Builder(this, CHANNEL_ID)
				: new Notification.Builder(this);
		b.setSmallIcon(android.R.drawable.ic_menu_camera)
				.setContentTitle("她看了一眼你的屏幕")
				.setContentText("就这一张，截完就不看了")
				.setOngoing(true)
				.setShowWhen(false);
		try {
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				startForeground(NOTI_ID, b.build(),
						ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
			} else {
				startForeground(NOTI_ID, b.build());
			}
		} catch (Exception e) {
			// 最常见的两个原因：清单里漏了 FOREGROUND_SERVICE_MEDIA_PROJECTION ✓、
			// 或者忘了 foregroundServiceType ✓（日志里能直接看到 ✓）
			Log.e(TAG, "截屏: startForeground 失败 " + e);
			PetShot.writeStatus(this, "failed");
			stopSelf();
			return START_NOT_STICKY;
		}

		// ② 再取 projection ✓（到这儿前台服务已经在了 ✓）
		MediaProjectionManager mgr =
				(MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
		if (mgr == null) {
			Log.e(TAG, "截屏: 没有 MediaProjectionManager ✗");
			PetShot.writeStatus(this, "failed");
			finish();
			return START_NOT_STICKY;
		}
		try {
			projection = mgr.getMediaProjection(code, data);
		} catch (Exception e) {
			Log.e(TAG, "截屏: getMediaProjection 失败 " + e);
			projection = null;
		}
		if (projection == null) {
			Log.e(TAG, "截屏: projection 是空的 ✗（授权被回收 / 服务类型不对 ✓）");
			PetShot.writeStatus(this, "failed");
			finish();
			return START_NOT_STICKY;
		}
		// 安卓 14+ 要求：建 VirtualDisplay **之前**先注册回调 ✓（不注册直接抛 IllegalStateException ✗）
		projection.registerCallback(new MediaProjection.Callback() {
			@Override
			public void onStop() {
				Log.i(TAG, "截屏: 系统把这次录屏收掉了 ✓");
			}
		}, ui);

		// ③ 建镜像 → 等第一帧 ✓
		DisplayMetrics dm = getResources().getDisplayMetrics();
		final int w = dm.widthPixels;
		final int h = dm.heightPixels;
		final int dpi = dm.densityDpi;
		try {
			reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2);
			// ⚠️ **不挂 onImageAvailable** ✗（2026-10-10 改的）：
			//   挂上它就会"第一帧就抓" ✓ —— 而那一帧很可能是**画面还在切的时候** ✗
			//   （我们刚被 `moveTaskToBack` 挪走 ✓，用户原来那个 App 正在回到前台 ✓）。
			//   现在改成：镜像先跑一会儿 ✓，到 SETTLE_MS 再取**最新**那一帧 ✓
			//   （队列里最多堆 2 张 ✓、我们一取就让位 ✓，不会把 SurfaceFlinger 顶住 ✓）
			display = projection.createVirtualDisplay("pet_shot", w, h, dpi,
					DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
					reader.getSurface(), null, ui);
		} catch (Exception e) {
			Log.e(TAG, "截屏: 建镜像失败 " + e);
			PetShot.writeStatus(this, "failed");
			finish();
			return START_NOT_STICKY;
		}
		Log.i(TAG, "截屏: 服务已就位（" + w + "×" + h + " ｜ " + dpi + "dpi ✓）→ "
				+ String.format("%.1f", SETTLE_MS / 1000.0) + " 秒后取最新那一帧 ✓");
		ui.postDelayed(new Runnable() {
			@Override
			public void run() {
				tryGrab(w, h, 0);
			}
		}, SETTLE_MS);
		// 兜底：万一一直取不到（有些 ROM 上首帧就是慢 ✓），别把服务挂着 ✗
		ui.postDelayed(new Runnable() {
			@Override
			public void run() {
				if (!done) {
					Log.e(TAG, "截屏: " + (GIVE_UP_MS / 1000) + " 秒没等到帧 ✗（认输，别挂着服务 ✓）");
					PetShot.writeStatus(PetShotService.this, "empty");
					finish();
				}
			}
		}, GIVE_UP_MS);
		return START_NOT_STICKY;      // 它是一次性的 ✓（系统顺手清掉也不用它自己回来 ✗）
	}

	/** 到点去取**最新**那一帧 ✓：取到了就转 Bitmap → 写 share_in.jpg → 收工 ✓
	 *  取不到就隔 100ms 再来 ✓（最多约 2.5 秒 ✓ —— 有些 ROM 上首帧就是慢 ✓） */
	private void tryGrab(int wantW, int wantH, int tries) {
		if (done || reader == null) {
			return;
		}
		Image img = null;
		try {
			img = reader.acquireLatestImage();
		} catch (Exception e) {
			Log.e(TAG, "截屏: 取帧失败 " + e);
			img = null;
		}
		if (img == null) {
			if (tries < 25) {
				final int t = tries + 1;
				ui.postDelayed(new Runnable() {
					@Override
					public void run() {
						tryGrab(wantW, wantH, t);
					}
				}, 100L);
			} else {
				Log.e(TAG, "截屏: 试了 2.5 秒还是没帧 ✗");
				PetShot.writeStatus(this, "empty");
				finish();
			}
			return;
		}
		done = true;
		try {
			Image.Plane p = img.getPlanes()[0];
			ByteBuffer buf = p.getBuffer();
			int rowStride = p.getRowStride();
			int pixelStride = p.getPixelStride();
			// ⚠️ 行是**有填充**的 ✗：一行实际占 rowStride 字节，末尾那点不是像素 ✓。
			//    直接按 width 建图 → 整张会**斜着错位** ✓（这是这个 API 最经典的一脚 ✓）
			int strideW = (pixelStride > 0) ? rowStride / pixelStride : wantW;
			Bitmap raw = Bitmap.createBitmap(strideW, img.getHeight(), Bitmap.Config.ARGB_8888);
			raw.copyPixelsFromBuffer(buf);
			Bitmap out = (strideW == wantW)
					? raw
					: Bitmap.createBitmap(raw, 0, 0, Math.min(wantW, strideW), img.getHeight());
			writeToShareIn(out);
			if (out != raw) {
				out.recycle();
			}
			raw.recycle();
		} catch (Exception e) {
			Log.e(TAG, "截屏: 转图失败 " + e);
			PetShot.writeStatus(this, "failed");
		} finally {
			try {
				img.close();
			} catch (Exception ignore) {
				// 关不掉就算了 ✓
			}
			finish();
		}
	}

	/** 落盘到 `files/share_in.jpg` ✓ —— 落盘那段和阶段 13 的无障碍那条**共用一处** ✓
	 *  （见 PetShot.writeShareIn ✓，两边只差"怎么拿到 Bitmap" ✓），这里只管写 ok 状态 ✓ */
	private void writeToShareIn(Bitmap b) {
		if (PetShot.writeShareIn(this, b)) {
			PetShot.writeStatus(this, "ok");
		}
	}

	/** 收尾：把投影**放掉**（不放掉状态栏会一直挂着投屏图标 ✗）→ 停服务 ✓ */
	private void finish() {
		try {
			if (display != null) {
				display.release();
			}
		} catch (Exception ignore) {
			// 放不掉就算了 ✓
		}
		display = null;
		try {
			if (reader != null) {
				reader.close();
			}
		} catch (Exception ignore) {
			// 同上 ✓
		}
		reader = null;
		try {
			if (projection != null) {
				projection.stop();
			}
		} catch (Exception ignore) {
			// 同上 ✓
		}
		projection = null;
		try {
			stopForeground(true);       // 通知跟着一起收掉 ✓（"看了一眼"就该只闪一下 ✓）
		} catch (Exception ignore) {
			// 同上 ✓
		}
		stopSelf();
		Log.i(TAG, "截屏: 收工（投影已放掉 ✓ 服务已停 ✓）");
	}

	@Override
	public void onDestroy() {
		// 兜一手：万一系统先杀服务（没走 finish ✓），也别把投影漏在外面 ✗
		if (projection != null || display != null) {
			finish();
		}
		super.onDestroy();
	}
}
