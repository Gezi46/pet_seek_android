package com.godot.game;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.util.Log;
import android.widget.RemoteViews;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;

/**
 * 阶段⑤（2026-10-11，用户要的"桌面小组件"）：桌面上摆一块小卡片，上面是她最近说的一句话 ✓。
 *
 * 为什么用 AppWidget 而不是别的 ✓：
 *   · 这是**安卓桌面原生**的格子 ✓ —— 用户长按桌面就能加，不用进我们 App ✓；
 *   · Godot 进程死了它也活着 ✓（卡片只是读一行文件 ✓），正好干"陪伴"这件事 ✓ ——
 *     她说过的话留在桌面上，人划着划着就看见了 ✓。
 *
 * ⚠️ 数据走**文件**，不走 JNI 传参 ✗→✓：GDScript 每听她说一句，就往
 * `files/widget_line.txt` 写两行（第一行是她的话、第二行是 unix 秒 ✓），
 * 然后调 `PetBridge.refreshWidget()` ✓。这边 update 时把文件读回来渲染 ✓。
 *   为什么不把句子当参数传进来 ✗：AppWidget 的更新是**广播**驱动的 ✓，
 *   参数只能塞 extras（长度受限、还得防截断 ✗）；而"她刚说了什么"本来就该落一份盘 ✓
 *   —— 进程被杀了、卡片照样读得到 ✓。
 */
public class PetWidget extends AppWidgetProvider {
	private static final String TAG = "GODOT";
	/** 和 GDScript 的 `user://widget_line.txt` 逐字一致 ✗（改一头另一头必须跟着改 ✓） */
	private static final String LINE_FILE = "widget_line.txt";

	/** 文件里还没写过时间（老格式/被截断）→ 不显示"多久以前" ✓ */
	private static final String DEFAULT_LINE = "（她还没开口…等她跟你说第一句 ✓）";

	@Override
	public void onUpdate(Context context, AppWidgetManager appWidgetManager, int[] appWidgetIds) {
		render(context, appWidgetManager, appWidgetIds, System.currentTimeMillis());
	}

	/** GDScript 每听她说一句就调这个 ✓（经 PetBridge.refreshWidget 转来 ✓） */
	public static void refreshWidget(Context c) {
		if (c == null) {
			return;
		}
		try {
			AppWidgetManager mgr = AppWidgetManager.getInstance(c);
			if (mgr == null) {
				return;
			}
			ComponentName me = new ComponentName(c, PetWidget.class);
			int[] ids = mgr.getAppWidgetIds(me);
			// 桌面上还没有这块卡片 → 没什么可刷的 ✓（别当错误 ✗）
			if (ids == null || ids.length == 0) {
				return;
			}
			render(c, mgr, ids, System.currentTimeMillis());
		} catch (Exception e) {
			Log.e(TAG, "小组件: 刷新失败 " + e);
		}
	}

	/** 读文件 → 渲染 → 贴到每一块卡片上 ✓ */
	private static void render(Context c, AppWidgetManager mgr, int[] ids, long nowMs) {
		try {
			String line = DEFAULT_LINE;
			long ts = 0L;
			String[] kv = readLine(c);
			if (kv != null) {
				if (!kv[0].isEmpty()) {
					line = kv[0];
				}
				try {
					ts = Long.parseLong(kv[1]);
				} catch (NumberFormatException ignored) {
					ts = 0L;      // 第二行坏了 → 只显示句子 ✓
				}
			}
			RemoteViews views = new RemoteViews(c.getPackageName(), R.layout.pet_widget);
			views.setTextViewText(R.id.widget_line, line);
			views.setTextViewText(R.id.widget_time, relText(nowMs, ts));
			// 点卡片 → 把她调到前台 ✓（用系统给的启动 intent ✓ —— 别名换了也不用改这里 ✓）
			Intent launch = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
			if (launch != null) {
				launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
				PendingIntent pi = PendingIntent.getActivity(c, 0, launch,
						PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
				views.setOnClickPendingIntent(R.id.widget_root, pi);
			}
			for (int id : ids) {
				mgr.updateAppWidget(id, views);
			}
			Log.i(TAG, "小组件: 刷新了 " + ids.length + " 块 ✓（" + relText(nowMs, ts) + "）");
		} catch (Exception e) {
			Log.e(TAG, "小组件: 渲染失败 " + e);
		}
	}

	/** 读 `files/widget_line.txt` ✓ → [句子, unix秒]；文件不在/读不了给 null ✓ */
	private static String[] readLine(Context c) {
		File f = new File(c.getFilesDir(), LINE_FILE);
		if (!f.exists() || !f.isFile() || f.length() == 0L) {
			return null;
		}
		BufferedReader r = null;
		try {
			r = new BufferedReader(new FileReader(f));
			String line = r.readLine();
			String ts = r.readLine();
			if (line == null) {
				return null;
			}
			return new String[] {line.trim(), ts == null ? "" : ts.trim()};
		} catch (Exception e) {
			Log.w(TAG, "小组件: 台词文件读不出来 " + e);
			return null;
		} finally {
			if (r != null) {
				try {
					r.close();
				} catch (Exception ignored) {
				}
			}
		}
	}

	/** "多久以前" ✓ —— 卡片上不显示绝对时间（没人心算 ✓），只显示相对 ✓ */
	private static String relText(long nowMs, long tsSec) {
		if (tsSec <= 0L) {
			return "";
		}
		long d = nowMs - tsSec * 1000L;
		if (d < 0L) {
			d = 0L;          // 时钟被改过 → 当"刚刚" ✓
		}
		if (d < 60_000L) {
			return "刚刚";
		}
		if (d < 3_600_000L) {
			return (d / 60_000L) + " 分钟前";
		}
		if (d < 86_400_000L) {
			return (d / 3_600_000L) + " 小时前";
		}
		return (d / 86_400_000L) + " 天前";
	}
}
