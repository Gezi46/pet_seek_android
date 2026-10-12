package com.godot.game;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

/**
 * 阶段 9（2026-10-09）：后台保活用的**前台服务**。
 *
 * 为什么要有它（实测，不是猜 ✓）：一按 HOME，Godot 的主循环就被系统暂停 ✗ ——
 * 那 150 秒里「每 1 分钟看一眼摄像头」一次都没触发 ✓、她一句本地台词也没出 ✓。
 * 安卓对后台 Activity 就是这么设计的（进程在、但不再被调度跑帧 ✓）。
 *
 * 一个前台服务能按住**进程** ✓，并且必须在通知栏挂一条常驻通知 ✓
 * （这不是我加的仪式，是安卓的硬规矩：前台服务就得让人看见 ✓）——
 * 正好也是用户认识它的方式：不想让她在后台跑了，把这条通知划掉/关掉就行 ✓。
 *
 * ⚠️ 光有服务**还不够** ✗：主循环停不停是引擎那边的判断 ✓ ——
 * 所以 GDScript 那边同时开一路**静音音频**（见 pet_mobile._start_keepalive ✓），
 * 那条才是"让她继续想事"的关键 ✓。这条到底成不成立，本次要**真机实测** ✓。
 *
 * ⚠️ targetSdk 是 36 ✓：安卓 14+ 起 `startForeground` **必须带类型** ✓，
 * 声明了类型还得在清单里配上对应权限 ✗ —— 两样都在
 * `android/build/src/standard/AndroidManifest.xml` 里 ✓（少一样就是启动即崩 ✓）。
 * 这里选 `mediaPlayback` ✓：我们的确在播一路（静音的 ✓）音频 ✓，类型对得上 ✓。
 */
public class PetService extends Service {
	private static final String TAG = "GODOT";
	private static final String CHANNEL_ID = "pet_keepalive";
	private static final int NOTI_ID = 0x9E01;

	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}

	/** 阶段 9c（2026-10-09）：由**服务自己**计时"喊一声" ✓
	 *
	 * 为什么不靠系统调度 ✗（真机实测，两条路都被押住）：
	 *   · AlarmManager → `dumpsys alarm` 写 `Reason=frozen` ✗（后台应用被 app freezer 冻住 ✓）
	 *   · JobScheduler → `Required: TIMING_DELAY` 永远不满足 ✗（同样被压着 ✓）
	 * 而**前台服务在跑的进程本身就是活的** ✓ —— 那就别绕远路 ✓：
	 * 直接在服务里 `postDelayed` ✓，到点自己发 ✓（不经过任何系统调度器 ✓）。
	 * 回前台时服务会被 stop ✓ → 这些回调跟着进程里的服务一起消失 ✓（不会回来后还追着喊 ✓）。
	 */
	private final Handler handler = new Handler(Looper.getMainLooper());

	private void scheduleNudges(long d0Ms, long d1Ms, long r0Ms, long r1Ms) {
		// ⚠️ 顺序即"台词文件里的行序" ✓ —— GDScript 那边按到点时间整份排好 ✓，
		// 谁先到点谁先消耗第一行 ✓（提醒和喊声混在一起也乱不了 ✓）
		long[] all = new long[] { d0Ms, d1Ms, r0Ms, r1Ms };
		for (int i = 0; i < all.length; i++) {
			long d = all[i];
			if (d <= 0) {
				continue;
			}
			final int idx = i;
			handler.postDelayed(new Runnable() {
				@Override
				public void run() {
					Log.i(TAG, "喊一声: 服务计时到点 #" + idx);
					// 阶段 10：**两条路一起走** ✓
					//   · 气泡（主路 ✓）—— 悬浮球是我自己画的 ✓，系统没法替我们决定它显不显示 ✓
					//   · 通知（备用 ✓）—— 这台 vivo 会把后台普通通知吞掉 ✗（实测 ✓），留着不碍事 ✓
					String line = PetNotifyReceiver.takeLine(PetService.this);
					if (line == null || line.trim().isEmpty()) {
						Log.i(TAG, "喊一声: 台词用完了，这次不喊 ✓");
						return;
					}
					PetNotifyReceiver.postLine(PetService.this, line);
					PetOverlay.showBubble(PetService.this, line);
				}
			}, d);
			Log.i(TAG, "喊一声: 服务已计时 #" + i + "（" + (d / 1000) + " 秒后）");
		}
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		// 安卓 8+ 必须先建渠道 ✓，否则通知根本不显示 ✗（低重要度：不出声、不弹横幅 ✓）
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			NotificationManager nm =
					(NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
			if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
				NotificationChannel ch = new NotificationChannel(
						CHANNEL_ID, "她在后台陪着你", NotificationManager.IMPORTANCE_LOW);
				ch.setDescription("关掉它 = 让她停下来，不再有任何后台行为");
				ch.setShowBadge(false);
				nm.createNotificationChannel(ch);
			}
		}

		Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
				? new Notification.Builder(this, CHANNEL_ID)
				: new Notification.Builder(this);
		// ⚠️ 小图标**不用**应用自己的图标 ✗：那是 mipmap 自适应图标，
		// 当通知小图标用会花掉/或直接报错 ✓ → 用系统自带的（够用，还省一个资源 ✓）
		b.setSmallIcon(android.R.drawable.presence_online)
				.setContentTitle("她在后台陪着你")
				.setContentText("你照常看别的就行，她会自己找话说")
				.setOngoing(true)          // 划不掉：前台服务必须显示着 ✓（要停就在设置里关掉这个功能 ✓）
				.setShowWhen(false);

		// 点一下通知就回到她跟前 ✓
		Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
		if (open != null) {
			open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
			int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
				piFlags |= PendingIntent.FLAG_IMMUTABLE;   // 安卓 12+ 要求写明可变性 ✓
			}
			b.setContentIntent(PendingIntent.getActivity(this, 0, open, piFlags));
		}

		try {
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				startForeground(NOTI_ID, b.build(),
						ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
			} else {
				startForeground(NOTI_ID, b.build());
			}
			Log.i(TAG, "保活: 前台服务已启动（mediaPlayback）");
		} catch (Exception e) {
			// 最常见的两个原因：清单里漏了 FOREGROUND_SERVICE_MEDIA_PLAYBACK 权限 ✓、
			// 或者忘了 foregroundServiceType ✓（日志里能直接看到 ✓）
			Log.e(TAG, "保活: startForeground 失败 " + e);
		}
		// 阶段 9c：把"喊一声"交给服务自己计时 ✓（参数由 GDScript 传进来 ✓，0 = 不用 ✓）
		// 阶段 9b 收尾（2026-10-11）：提醒事项的两格也在这儿 ✓ —— 四个延时一起排 ✓，
		// 到点各消耗台词文件里一行 ✓（GDScript 按时间顺序整份写好的 ✓，行序 = 时间序 ✓）
		if (intent != null) {
			long d0 = intent.getLongExtra("nudge0_ms", 0L);
			long d1 = intent.getLongExtra("nudge1_ms", 0L);
			long r0 = intent.getLongExtra("remind0_ms", 0L);
			long r1 = intent.getLongExtra("remind1_ms", 0L);
			if (d0 > 0 || d1 > 0 || r0 > 0 || r1 > 0) {
				scheduleNudges(d0, d1, r0, r1);
			}
		}
		// START_STICKY：被系统顺手清掉时希望它自己回来 ✓（她该一直在 ✓）
		return START_STICKY;
	}

	@Override
	public void onDestroy() {
		// ⚠️ 停服务时必须把没到点的回调**撤掉** ✗ —— 真机踩到：
		// 停止服务并不会清掉已经 postDelayed 的 Runnable ✓，它挂在进程的主线程 Handler 上 ✓，
		// 于是"你回来之后她还追着喊"✗（日志里就是 `服务计时到点` 在你回前台之后才打出来 ✓）
		handler.removeCallbacksAndMessages(null);
		Log.i(TAG, "保活: 前台服务已停止（没到点的喊话已撤销 ✓）");
		super.onDestroy();
	}
}
