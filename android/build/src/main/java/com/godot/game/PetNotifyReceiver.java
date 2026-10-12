package com.godot.game;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.List;

/**
 * 阶段 9b（2026-10-09）：**闹钟式台词通知** —— 她退到后台之后，偶尔给你发一条话。
 *
 * 为什么不是"让 Godot 在后台继续跑"✗（阶段 9 的实测结论 ✓）：
 *   前台服务能把**进程**按住 ✓，但引擎的主循环照样被系统暂停 ✗ ——
 *   那 240 秒里一次心跳都没打 ✓。所以"她在后台思考"这条路，**在当前引擎上走不通** ✗
 *   （除非改用 Godot-as-library 把引擎塞进 Service ✗，那是另一整摊 ✓）。
 *
 * 但"**她在你没看的时候喊你一声**"这件事完全做得到 ✓ ——
 * 不需要引擎活着 ✓：系统到点唤醒这个接收器 ✓，它从**台词文件**里取一句发成通知 ✓。
 * 台词是 GDScript 在**退到后台那一刻**写好的 ✓（那时引擎还没停 ✓，她的心情/人设都还是活的 ✓），
 * 所以声音还是她的 ✓，只是"思考"发生在退后台之前 ✓。
 *
 * 台词文件：`files/keepalive_lines.txt`（= GDScript 的 `user://keepalive_lines.txt` ✓），
 * 一行一句 ✓；**每喊一次消耗一行** ✓ —— 行数用完就自然不再喊 ✓（不需要额外记状态 ✓）。
 * 回前台时 GDScript 会把闹钟全部撤掉、把文件清空 ✓ → 不会留下"回来还追着喊" ✗。
 */
public class PetNotifyReceiver extends BroadcastReceiver {
	private static final String TAG = "GODOT";
	private static final String CHANNEL_ID = "pet_nudge";
	private static final String FILE_NAME = "keepalive_lines.txt";
	private static final int NOTI_ID = 0x9E02;

	@Override
	public void onReceive(Context context, Intent intent) {
		fireOnce(context);
	}

	/** "喊一声"的全部动作：取一句台词 → 发成通知 ✓。
	 *
	 * ⚠️ 抽成 static 是因为现在**真正的触发源是 Job**（`PetNudgeJobService` ✓）——
	 * 见那个文件头部：AlarmManager 会被"应用被冻结"挡住 ✗，JobScheduler 才唤得醒 ✓。
	 * 这个接收器留着是给"以后想手动/别的方式触发"用的 ✓，逻辑只有一份 ✓。
	 */
	public static void fireOnce(Context context) {
		String line = takeLine(context);
		if (line == null || line.trim().isEmpty()) {
			Log.i(TAG, "喊一声: 台词用完了，这次不喊 ✓");
			return;
		}
		postLine(context, line);
	}

	/** 取走一句台词（**同时把它从文件里删掉** ✓）；没了给 null ✓ */
	public static String takeLine(Context context) {
		return takeFirstLine(context);
	}

	/** 把一句话发成通知 ✓（第二步 ✓ —— 服务那边是先 take 再决定要不要另外冒气泡 ✓） */
	public static void postLine(Context context, String line) {
		if (line == null || line.trim().isEmpty()) {
			return;
		}
		// 安卓 8+ 先建渠道 ✓ —— 这条用 DEFAULT 重要度 ✓：该响就响、该弹就弹（她找你嘛 ✓）
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			NotificationManager nm =
					(NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
			if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
				NotificationChannel ch = new NotificationChannel(
						CHANNEL_ID, "她喊你", NotificationManager.IMPORTANCE_DEFAULT);
				ch.setDescription("你走开的时候，她偶尔会给你留一句话");
				nm.createNotificationChannel(ch);
			}
		}
		Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
				? new Notification.Builder(context, CHANNEL_ID)
				: new Notification.Builder(context);
		b.setSmallIcon(android.R.drawable.presence_online)
				.setContentTitle("她")           // 名字条上是她的名字，通知栏就写"她" ✓
				.setContentText(line)
				.setStyle(new Notification.BigTextStyle().bigText(line))
				.setAutoCancel(true)
				.setShowWhen(true);
		Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
		if (open != null) {
			open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
			int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
				piFlags |= PendingIntent.FLAG_IMMUTABLE;
			}
			b.setContentIntent(PendingIntent.getActivity(context, 0, open, piFlags));
		}
		try {
			NotificationManager nm =
					(NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
			if (nm != null) {
				nm.notify(NOTI_ID, b.build());
				Log.i(TAG, "喊一声: 已发出（还剩 " + countLines(context) + " 句）");
			}
		} catch (Exception e) {
			Log.e(TAG, "喊一声: 发通知失败 " + e);
		}
	}

	/** 取走第一句（并把它从文件里删掉 ✓）。没文件/空了给 null ✓ */
	private static String takeFirstLine(Context context) {
		try {
			File f = new File(context.getFilesDir(), FILE_NAME);
			if (!f.exists()) {
				return null;
			}
			List<String> lines = readLines(f);
			if (lines.isEmpty()) {
				return null;
			}
			String first = lines.remove(0);
			writeLines(f, lines);
			return first;
		} catch (Exception e) {
			Log.e(TAG, "喊一声: 读台词失败 " + e);
			return null;
		}
	}

	private static int countLines(Context context) {
		try {
			File f = new File(context.getFilesDir(), FILE_NAME);
			return f.exists() ? readLines(f).size() : 0;
		} catch (Exception e) {
			return 0;
		}
	}

	private static List<String> readLines(File f) throws Exception {
		List<String> out = new ArrayList<>();
		try (BufferedReader r = new BufferedReader(
				new InputStreamReader(new FileInputStream(f), "UTF-8"))) {
			String s;
			while ((s = r.readLine()) != null) {
				if (!s.trim().isEmpty()) {
					out.add(s);
				}
			}
		}
		return out;
	}

	private static void writeLines(File f, List<String> lines) throws Exception {
		try (FileOutputStream o = new FileOutputStream(f, false)) {
			for (String s : lines) {
				o.write((s + "\n").getBytes("UTF-8"));
			}
		}
	}
}
