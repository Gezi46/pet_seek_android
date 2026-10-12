package com.godot.game;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.text.InputType;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * 阶段 10（2026-10-09，用户要的 A 方案）：**悬浮球 + 她说话的气泡**。
 *
 * 为什么必须用原生 View（不能是 Godot 画的）✗：
 *   实测过（阶段 9）：手机上一退到后台，**Godot 的主循环就被系统暂停** ✓ ——
 *   所以"浮在别的 App 上还能跟她说话"这件事，只能在 **Java 侧**画 ✓。
 *
 * 这一版做两件事（第三件"在悬浮窗里打字"接着做 ✓）：
 *   · **悬浮球** ✓ —— 那张脸是她在**真机上**截的正视图头像 ✓（见 pet_mobile._capture_face ✓，
 *     存成 `files/pet_face.png` ✓ = 这里读的那个 ✓）。可以拖动 ✓；点一下把她叫回前台 ✓。
 *   · **气泡** ✓ —— 她主动说话时，在原悬浮球旁边冒出一个小气泡 ✓
 *     （由 `PetService` 的服务内计时触发 ✓，见 PetService.scheduleNudges ✓）。
 *     ⚠️ 为什么用气泡而不是普通通知 ✗：这台 vivo 会把**后台应用的普通通知**吞掉 ✓
 *     （实测：应用层 `已发出` ✓、通知栏里没有 ✗），而**悬浮窗是我们自己画的** ✓，
 *     系统没法替我们决定它显不显示 ✓✓
 *
 * ⚠️ 悬浮窗要用户**单独授权**（`SYSTEM_ALERT_WINDOW` ✓ 就是要"显示在其他应用上层"那个开关 ✓）：
 *   `canDraw()` 检查 ✓ / `request()` 拉起系统那个授权页 ✓（见 PetBridge 的同名方法 ✓）
 */
public class PetOverlay {
	private static final String TAG = "GODOT";
	private static final String FACE_FILE = "pet_face.png";
	/** 悬浮球直径（dp）✓ —— 48dp 是"手指点得着"的下限 ✓ */
	private static final int BALL_DP = 52;
	/** 双击判定的窗口（毫秒）✓ —— 手点两下一般 150~300ms ✓。
	 *  ⚠️ 2026-10-10 从 350 放宽到 **420** ✗→✓（用户报的"双击没截图"✓）：
	 *    悬浮球这会儿还兼着"单击开面板"✓，手上节奏常常比 350 慢一点 ✓，
	 *    第二下落在窗口外就被当成又一次单击、只是把面板关了又开 ✗（观感就是"怎么都没截图"✓）。
	 *    420 仍远小于"两次真的单击"的间隔（人一般 500ms+ ✓），不会误判 ✗
	 *    （另外面板上已经补了一个明摆着的「截图」按钮 ✓，见 showPanel ✓，那是更稳的入口 ✓）。 */
	private static final long DOUBLE_TAP_MS = 420L;

	// ---- 阶段 12（2026-10-10，用户要的）：球会眨眼、会微微晃 ✓ ----
	/** 待机帧的文件名模板（= GDScript 的 `user://pet_face_%d.png` ✓，两边**逐字一致** ✗） */
	private static final String FACE_FRAME_TMPL = "pet_face_%d.png";
	/** 眨眼那两张：半闭 / 闭 ✓ */
	private static final String FACE_BLINK_HALF = "pet_face_b0.png";
	private static final String FACE_BLINK_CLOSED = "pet_face_b1.png";
	/** GDScript 留的小清单：`帧数 每帧毫秒 眨眼张数` ✓ */
	private static final String FACE_MANIFEST = "pet_face_frames.txt";
	/** 最多找这么多帧 ✓（序列是**连续**的 ✓，缺一张就当到头了 ✓）
	 *  ⚠️ 得比 GDScript 那边的 FACE_FRAMES 大 ✗ —— 那边现在是 36 ✓（用户 2026-10-10 要更顺 ✓） */
	private static final int FACE_MAX_FRAMES = 64;
	/** 眨眼间隔（毫秒）—— 真人 3~4 秒一次 ✓，这里 2.6~5.2 秒随机 ✓（别机械地准点 ✗） */
	private static final long BLINK_MIN_MS = 2600L;
	private static final long BLINK_SPAN_MS = 2600L;
	/** 拖动 / 按下去那一下缩到多少 ✓ */
	private static final float PRESS_SCALE = 0.90f;

	/** 轮播用它 ✓（球一没就自己停 ✓，见 frameTick ✓） */
	private static final Handler anim = new Handler(Looper.getMainLooper());
	/** 球那张 ImageView（动画往它身上贴帧 ✓） */
	private static ImageView ballIv = null;
	private static Bitmap[] idleFrames = null;      // 待机那一圈 ✓
	private static Bitmap[] blinkSeq = null;        // 半闭 → 闭 → 半闭 ✓
	private static int idleDwell = 200;             // 每帧停多久（GDScript 算好的 ✓，见清单 ✓）
	private static int idleIdx = 0;
	private static int idleDir = 1;                 // 往返播：+1 去 / -1 回 ✓（见 frameTick ✓）
	private static int blinkStep = -1;              // -1 = 这会儿不在眨眼 ✓

	private static Activity activity = null;
	private static WindowManager wm = null;
	private static View ball = null;
	private static View bubble = null;
	private static final Handler ui = new Handler(Looper.getMainLooper());
	/** 球心坐标（屏幕左上角为准 ✓）；气泡贴着它摆 ✓ */
	private static int ballX = 0;
	private static int ballY = 0;

	// ---- 阶段 10 第三件（2026-10-09）：**点球弹出的小聊天面板** ✓ ----
	/** 面板本体 / 上面那块对话区 / 底下那个输入框 ✓ */
	private static View panel = null;
	private static TextView panelLog = null;
	private static EditText panelInput = null;
	private static ScrollView panelScroll = null;
	/** 面板里这几句（只在这条会话里有效 ✓）—— 发给模型当"刚才聊过什么" ✓ */
	private static final List<String> panelHistory = new ArrayList<>();
	/** 她说的话也**落一份盘** ✓：`files/overlay_chat.txt` ✓
	 *  （GDScript 回前台时把它并进正式聊天记录 ✓ —— 格式由 GDScript 说了算 ✓，
	 *    这边只负责一行一行地追加 ✓，免得两边争同一个 JSON 文件 ✗） */
	private static final String CHAT_LOG = "overlay_chat.txt";

	public static void setActivity(Activity a) {
		activity = a;
	}

	/** 有没有"显示在其他应用上层"这个授权 ✓（安卓 6 以下不用授权 ✓） */
	public static boolean canDraw(Context c) {
		if (c == null) {
			return false;
		}
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
			return true;
		}
		return Settings.canDrawOverlays(c);
	}

	/** 拉起系统那个授权页 ✓（用户点一下"允许"就回来了 ✓） */
	public static void request(Context c) {
		if (c == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
			return;
		}
		try {
			Intent i = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
					Uri.parse("package:" + c.getPackageName()));
			i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
			c.startActivity(i);
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 拉起授权页失败 " + e);
		}
	}

	/** 显示悬浮球 ✓（已经显示就什么都不做 ✓） */
	public static void show() {
		if (activity == null) {
			Log.e(TAG, "悬浮球: 还没有 Activity");
			return;
		}
		if (!canDraw(activity)) {
			Log.w(TAG, "悬浮球: 还没拿到「显示在其他应用上层」授权 ✗");
			return;
		}
		ui.post(new Runnable() {
			@Override
			public void run() {
				if (ball != null) {
					return;
				}
				try {
					buildBall();
					// ⚠️ 这一行要写全 ✗ —— "用户看不见球"时全靠它分辨：
					//    位置是不是跑屏幕外了 ✓、有没有真挂进窗口 ✓、授权还在不在 ✓
					//    （2026-10-09 就是缺这些信息，只能靠猜 ✓）
					Log.i(TAG, "悬浮球: 已显示 ✓（位置 " + ballX + "," + ballY
							+ " ｜ 挂上窗口=" + ball.isAttachedToWindow()
							+ " ｜ 可见=" + (ball.getVisibility() == View.VISIBLE)
							+ " ｜ canDrawOverlays=" + Settings.canDrawOverlays(activity) + "）");
				} catch (Exception e) {
					Log.e(TAG, "悬浮球: 显示失败 " + e);
				}
			}
		});
	}

	/** 球现在挂着没有 ✓（给 GDScript 问的 ✓ —— 别让它靠"没抛异常"猜 ✗） */
	public static boolean isShown() {
		return ball != null;
	}

	// ------------------------------------------------------------------ 面板（点球弹出来的小聊天框）

	private static void togglePanel() {
		if (panel == null) {
			showPanel();
		} else {
			hidePanel();
		}
	}

	private static void showPanel() {
		if (activity == null || wm == null) {
			Log.e(TAG, "悬浮球: 面板开不了（没有 Activity / WindowManager）");
			return;
		}
		try {
			LinearLayout box = new LinearLayout(activity);
			box.setOrientation(LinearLayout.VERTICAL);
			GradientDrawable g = new GradientDrawable();
			g.setCornerRadius(dp(activity, 16));
			g.setColor(Color.parseColor("#F01A2430"));
			g.setStroke(dp(activity, 1), Color.parseColor("#66FFFFFF"));
			box.setBackground(g);
			box.setPadding(dp(activity, 12), dp(activity, 10), dp(activity, 12), dp(activity, 10));

			panelLog = new TextView(activity);
			panelLog.setTextColor(Color.parseColor("#FFF2F6FF"));
			panelLog.setTextSize(14f);
			panelLog.setText("（在这儿跟她说一句 ✓ 她的话也会记进聊天记录 ✓）");
			ScrollView sc = new ScrollView(activity);
			sc.addView(panelLog);
			sc.setLayoutParams(new LinearLayout.LayoutParams(dp(activity, 232), dp(activity, 148)));
			panelScroll = sc;
			box.addView(sc);

			LinearLayout row = new LinearLayout(activity);
			row.setOrientation(LinearLayout.HORIZONTAL);
			panelInput = new EditText(activity);
			panelInput.setHint("跟她说点什么…");
			panelInput.setHintTextColor(Color.parseColor("#88FFFFFF"));
			panelInput.setTextColor(Color.parseColor("#FFFFFFFF"));
			panelInput.setInputType(InputType.TYPE_CLASS_TEXT);
			panelInput.setLayoutParams(new LinearLayout.LayoutParams(0,
					LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
			row.addView(panelInput);
			Button send = new Button(activity);
			send.setText("说");
			send.setOnClickListener(new View.OnClickListener() {
				@Override public void onClick(View v) {
					sendFromPanel();
				}
			});
			row.addView(send);
			box.addView(row);

			// ⚠️ 这一排按钮是**用户报的 bug 修出来的** ✗（2026-10-10）：
			//    原先面板上只有「说」和「打开她」✓，要收起来只能"再点一下球" ✓ ——
			//    可球一旦不在了（拖到屏幕外 ✓／你从"最近任务"直接回她跟前、球已被收掉 ✓），
			//    面板就**留在屏幕上没人管** ✗ → 用户那句"弹窗打开后对话关不上"就是它 ✓。
			//    两个修法都要：① 面板上有个明摆着的「收起」✓；
			//                ② 收球时**连面板一起收** ✓（见 hide ✓）
			// 2026-10-10 排布也顺手整了 ✓：三个按钮**平分一行**（各 weight=1 ✓）——
			// 原来两个按钮各自按文字宽度撑 ✓，加了「截图」之后长短不一会很别扭 ✓
			LinearLayout btns = new LinearLayout(activity);
			btns.setOrientation(LinearLayout.HORIZONTAL);
			// ⚠️ 宽度必须**指定**（不能让它按内容撑 ✗）：三个按钮都是 weight=1 + 宽度 0 ✓，
			//    父容器要是 WRAP_CONTENT，它们会各自被量成 0 宽 → 整排看不见 ✓。
			//    MATCH_PARENT = 跟上面那块对话区一样宽（232dp ✓），三等分正好 ✓
			btns.setLayoutParams(new LinearLayout.LayoutParams(
					LinearLayout.LayoutParams.MATCH_PARENT,
					LinearLayout.LayoutParams.WRAP_CONTENT));
			// ⚠️「截图」这一颗是**用户报的 bug 的正解** ✗→✓（2026-10-10"双击没截图"✓）：
			//    面板开着时，双击更像"关一下再开一下"✓（点球=开合面板 ✓，见 onTouch ✓），
			//    手感上根本对不准 ✓ —— 直接给一颗明摆着的按钮，比让他去掐那个节奏靠谱得多 ✓✓
			btns.addView(panelBtn("截图", new View.OnClickListener() {
				@Override public void onClick(View v) {
					// 先把手里的面板收掉再截 ✓：截的是**整个屏幕** ✓，
					// 面板开着就会一起被拍进去 ✗（她"看见"自己那块板子很怪 ✓）
					hidePanel();
					PetShot.request(activity);
				}
			}));
			btns.addView(panelBtn("打开她", new View.OnClickListener() {
				@Override public void onClick(View v) {
					openApp();
				}
			}));
			btns.addView(panelBtn("收起", new View.OnClickListener() {
				@Override public void onClick(View v) {
					hidePanel();
				}
			}));
			box.addView(btns);

			WindowManager.LayoutParams p = new WindowManager.LayoutParams(
					WindowManager.LayoutParams.WRAP_CONTENT,
					WindowManager.LayoutParams.WRAP_CONTENT,
					overlayType(),
					// ⚠️ 面板**不能**加 FLAG_NOT_FOCUSABLE ✗ —— 加了就收不到键盘输入 ✓
					WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
					PixelFormat.TRANSLUCENT);
			p.gravity = Gravity.TOP | Gravity.START;
			// ⚠️ 位置得**夹进屏幕**（2026-10-10 顺手修的 ✗）：原来不管球在哪儿都往球**下面**摆 ✓，
			//    球被拖到屏幕下沿时面板整个跑到屏幕外 ✗ —— "弹出来了但看不见" ✓，
			//    和"关不上"是同一个感受 ✓。规则：优先摆球下面；下面放不下就摆**球上面** ✓；
			//    两边都卡边时也保证**不压住球**（球是唯一能再点一下的抓手 ✓）
			android.util.DisplayMetrics dm = activity.getResources().getDisplayMetrics();
			int estH = dp(activity, 300);        // 面板估高（宁可比实际大一点 ✓）
			int px = Math.max(0, Math.min(ballX - dp(activity, 16),
					Math.max(0, dm.widthPixels - dp(activity, 264))));
			int below = ballY + dp(activity, BALL_DP) + dp(activity, 8);
			int above = ballY - dp(activity, 8) - estH;
			p.x = px;
			p.y = (below + estH <= dm.heightPixels) ? below : Math.max(0, above);
			// 键盘弹出来时把面板顶上去 ✓（不然输入框正好被键盘盖住 ✗）
			p.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
					| WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE;
			wm.addView(box, p);
			panel = box;
			panelInput.requestFocus();
			InputMethodManager imm = (InputMethodManager)
					activity.getSystemService(Context.INPUT_METHOD_SERVICE);
			if (imm != null) {
				imm.showSoftInput(panelInput, InputMethodManager.SHOW_IMPLICIT);   // 不少 ROM 不自动弹 ✗
			}
			Log.i(TAG, "悬浮球: 面板已弹出 ✓");
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 弹面板失败 " + e);
		}
	}

	private static void hidePanel() {
		try {
			if (activity != null && panelInput != null) {
				InputMethodManager imm = (InputMethodManager)
						activity.getSystemService(Context.INPUT_METHOD_SERVICE);
				if (imm != null) {
					imm.hideSoftInputFromWindow(panelInput.getWindowToken(), 0);
				}
			}
		} catch (Exception ignore) {
			// 收键盘失败无所谓 ✓
		}
		removeView(panel);
		panel = null;
		panelLog = null;
		panelInput = null;
		panelScroll = null;
		Log.i(TAG, "悬浮球: 面板已收起 ✓");
	}

	/** 面板里追加一行 ✓ + 滚到底 ✓ */
	private static void appendLog(String line) {
		if (panelLog == null) {
			return;
		}
		panelLog.append((panelLog.getText().length() == 0 ? "" : "\n") + line);
		if (panelScroll != null) {
			final ScrollView s = panelScroll;
			s.post(new Runnable() {
				@Override public void run() {
					s.fullScroll(View.FOCUS_DOWN);
				}
			});
		}
	}

	/** 把最后一行换掉 ✓（"她：……"那个占位 → 真回复 ✓） */
	private static void replaceLast(String line) {
		if (panelLog == null) {
			return;
		}
		String s = String.valueOf(panelLog.getText());
		int i = s.lastIndexOf('\n');
		panelLog.setText(i >= 0 ? s.substring(0, i + 1) + line : line);
	}

	private static String historyBlock() {
		StringBuilder sb = new StringBuilder();
		int from = Math.max(0, panelHistory.size() - 6);
		for (int i = from; i < panelHistory.size(); i++) {
			sb.append(panelHistory.get(i)).append('\n');
		}
		return sb.toString().trim();
	}

	/** "说"按钮：把这句话发出去 ✓（真正的请求在 PetChatOnce ✓，开线程做的 ✓） */
	private static void sendFromPanel() {
		if (panelInput == null) {
			return;
		}
		String t = panelInput.getText().toString().trim();
		if (t.isEmpty()) {
			return;
		}
		panelInput.setText("");
		appendLog("我：" + t);
		panelHistory.add("主人：" + t);
		appendOverlayChat("主人", t);
		appendLog("她：……");
		PetChatOnce.send(activity, t, historyBlock(), new PetChatOnce.Cb() {
			@Override public void ok(final String reply) {
				ui.post(new Runnable() {
					@Override public void run() {
						replaceLast("她：" + reply);
						panelHistory.add("她：" + reply);
						appendOverlayChat("她", reply);
					}
				});
			}
			@Override public void fail(final String why) {
				ui.post(new Runnable() {
					@Override public void run() {
						replaceLast("她：（没答上来：" + why + "）");
					}
				});
			}
		});
	}

	/** 她在悬浮窗里说的话**落一份盘** ✓（`files/overlay_chat.txt` ✓）——
	 *  回前台时由 GDScript 并进正式聊天记录 ✓（格式归 GDScript 管 ✓，这边只追加行 ✓） */
	private static void appendOverlayChat(String who, String text) {
		try {
			File f = new File(activity.getFilesDir(), CHAT_LOG);
			try (FileOutputStream o = new FileOutputStream(f, true)) {
				o.write((who + "：" + text + "\n").getBytes("UTF-8"));
			}
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 聊天记录落盘失败 " + e);
		}
	}

	/** 收起来 ✓（她回到前台时收 ✓ —— 你正看着她，球就是多余的 ✓） */
	public static void hide() {
		ui.post(new Runnable() {
			@Override
			public void run() {
				boolean had = ball != null;
				stopFrames();               // 阶段 12：球没了，就别再往"空气"上贴帧 ✗
				removeView(ball);
				ball = null;
				ballIv = null;
				removeView(bubble);
				bubble = null;
				// ⚠️ **面板也要一起收** ✗（2026-10-10 用户报的"弹窗打开后对话关不上"）：
				//    球一没了，面板上又只有"说 / 打开她"两句 ✓，
				//    于是它**再也没有关掉的门**了 ✗（唯一那条是"再点一下球" ✓，球已经不在 ✓）。
				//    所以收球的时候连它一起收 ✓ —— 回她跟前时屏幕上就该只剩她自己 ✓
				if (panel != null) {
					hidePanel();
				}
				if (had) {
					Log.i(TAG, "悬浮球: 已收起 ✓");     // 静默地收掉过，害得排查时只能猜 ✗
				}
			}
		});
	}

	/** 她说一句话：在她的球旁边冒一个气泡 ✓，几秒后自己消失 ✓ */
	public static void showBubble(Context ctx, final String text) {
		if (ctx == null || text == null || text.trim().isEmpty()) {
			return;
		}
		final Context app = ctx.getApplicationContext();
		ui.post(new Runnable() {
			@Override
			public void run() {
				try {
					if (ball == null) {
						// 球没在（没授权 / 没退后台）→ 这时候气泡没地方贴，就不显示了 ✓
						Log.i(TAG, "悬浮球: 球不在，气泡跳过");
						return;
					}
					if (bubble != null) {
						removeView(bubble);
						bubble = null;
					}
					bubble = buildBubble(app, text);
					wm.addView(bubble, bubbleParams(app, text));
					// 8 秒后自己收 ✓（她不会一直挂在你屏幕上 ✗）
					ui.postDelayed(new Runnable() {
						@Override
						public void run() {
							removeView(bubble);
							bubble = null;
						}
					}, 8000L);
					Log.i(TAG, "悬浮球: 气泡已显示 ✓");
				} catch (Exception e) {
					Log.e(TAG, "悬浮球: 显示气泡失败 " + e);
				}
			}
		});
	}

	// ------------------------------------------------------------------ 建视图 / 工具

	private static int dp(Context c, float v) {
		return Math.round(v * c.getResources().getDisplayMetrics().density);
	}

	// ---- 阶段 13（2026-10-10）：球的位置管理（拖拽夹边 + 松手吸边 ✓）----

	/** 把球心夹进屏幕 ✓ —— **至少留大半个球**在外面看得见、点得着 ✓
	 *  （负数 / 超出下沿都会让"球不见了但功能还在"✗，那是排查起来最费劲的一种 ✓） */
	private static void clampBall() {
		if (activity == null) {
			return;
		}
		android.util.DisplayMetrics dm = activity.getResources().getDisplayMetrics();
		int size = dp(activity, BALL_DP);
		int half = size / 2;
		ballX = Math.max(-half, Math.min(ballX, dm.widthPixels - half));
		ballY = Math.max(0, Math.min(ballY, Math.max(0, dm.heightPixels - size)));
	}

	/** 松手：**吸附到最近的左右边** ✓（带一小段动画 ✓，别"啪"地闪过去 ✗） */
	private static void snapToEdge(final View v) {
		if (activity == null || wm == null) {
			return;
		}
		android.util.DisplayMetrics dm = activity.getResources().getDisplayMetrics();
		int size = dp(activity, BALL_DP);
		int margin = dp(activity, 8);
		int leftX = margin;
		int rightX = Math.max(leftX, dm.widthPixels - size - margin);
		clampBall();
		final int targetX = (ballX + size / 2 < dm.widthPixels / 2) ? leftX : rightX;
		if (ballX == targetX) {
			// 已经在边上（或只差一点点）→ 直接落位 ✓，不用为 0 距离播一段动画 ✓
			ballX = targetX;
			return;
		}
		final WindowManager.LayoutParams lp = (WindowManager.LayoutParams) v.getLayoutParams();
		android.animation.ValueAnimator va =
				android.animation.ValueAnimator.ofInt(ballX, targetX);
		va.setDuration(170L);
		va.addUpdateListener(new android.animation.ValueAnimator.AnimatorUpdateListener() {
			@Override public void onAnimationUpdate(android.animation.ValueAnimator a) {
				ballX = (Integer) a.getAnimatedValue();
				lp.x = ballX;
				lp.y = ballY;
				try {
					wm.updateViewLayout(v, lp);
				} catch (Exception ignore) {
					// 动画途中被系统拦一下 → 忽略，下一帧还会接着动 ✓
				}
			}
		});
		va.start();
	}

	/** 面板底部那一排小按钮 ✓（三个**平分一行** ✓）—— 样式集中在一处，以后加按钮只动这里 ✓ */
	private static Button panelBtn(String text, View.OnClickListener l) {
		Button b = new Button(activity);
		b.setText(text);
		b.setAllCaps(false);            // 中文没有大小写，但默认的 CAPS 会改字样 → 关掉 ✓
		b.setTextSize(13f);
		b.setMinWidth(0);
		b.setMinimumWidth(0);
		b.setPadding(0, 0, 0, 0);
		b.setLayoutParams(new LinearLayout.LayoutParams(0,
				LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
		b.setOnClickListener(l);
		return b;
	}

	private static int overlayType() {
		return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
				? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
				: WindowManager.LayoutParams.TYPE_PHONE;
	}

	private static void removeView(View v) {
		if (v != null && wm != null) {
			try {
				wm.removeView(v);
			} catch (Exception ignore) {
				// 没加上去 / 已经移除了 → 忽略 ✓
			}
		}
	}

	/** 悬浮球本体：一张**圆形的她的脸** ✓；可拖动 ✓；点一下把她叫回前台 ✓ */
	private static void buildBall() {
		wm = (WindowManager) activity.getSystemService(Context.WINDOW_SERVICE);
		int size = dp(activity, BALL_DP);
		ImageView iv = new ImageView(activity);
		iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
		Bitmap bm = loadFace(activity);
		if (bm != null) {
			iv.setImageBitmap(bm);
		} else {
			// 还没截到头像（或读不到）→ 先用一个圆点顶着 ✓（功能不受影响 ✓，只是不好看 ✓）
			GradientDrawable dot = new GradientDrawable();
			dot.setShape(GradientDrawable.OVAL);
			dot.setColor(Color.parseColor("#8FBCFF"));
			iv.setBackground(dot);
		}
		// 一圈淡描边：不管有没有头像，球都得看得出是个"圆" ✓
		GradientDrawable ring = new GradientDrawable();
		ring.setShape(GradientDrawable.OVAL);
		ring.setColor(Color.parseColor("#22FFFFFF"));
		ring.setStroke(dp(activity, 2), Color.parseColor("#CCFFFFFF"));

		final WindowManager.LayoutParams p = new WindowManager.LayoutParams(
				size, size, overlayType(),
				WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
						| WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
				PixelFormat.TRANSLUCENT);
		p.gravity = Gravity.TOP | Gravity.START;
		ballX = dp(activity, 8);
		ballY = dp(activity, 220);
		p.x = ballX;
		p.y = ballY;

		iv.setOnTouchListener(new View.OnTouchListener() {
			private int downX, downY, startX, startY;
			private boolean moved;
			/** 上一次"点一下"的时刻（毫秒 ✓）—— 双击判定用它 ✓（阶段 11 ✓） */
			private long lastTapMs = 0L;

			@Override
			public boolean onTouch(View v, MotionEvent e) {
				switch (e.getActionMasked()) {
					case MotionEvent.ACTION_DOWN:
						downX = (int) e.getRawX();
						downY = (int) e.getRawY();
						startX = ballX;
						startY = ballY;
						moved = false;
						// 阶段 12：**一按就缩一下** ✓ —— 手指底下有反应，才像"捏住了她" ✓
						v.animate().scaleX(PRESS_SCALE).scaleY(PRESS_SCALE).setDuration(90).start();
						return true;
					case MotionEvent.ACTION_MOVE:
						int dx = (int) e.getRawX() - downX;
						int dy = (int) e.getRawY() - downY;
						if (Math.abs(dx) > dp(activity, 6) || Math.abs(dy) > dp(activity, 6)) {
							moved = true;
						}
						if (moved) {
							ballX = startX + dx;
							ballY = startY + dy;
							// 阶段 13：拖的时候也**夹着**她 ✓ —— 至少留大半个球在屏幕里 ✓
							//（不然一甩就把她丢到屏幕外 ✓，那颗球是唯一能再点着她的抓手 ✗）
							clampBall();
							WindowManager.LayoutParams lp =
									(WindowManager.LayoutParams) v.getLayoutParams();
							lp.x = ballX;
							lp.y = ballY;
							try {
								wm.updateViewLayout(v, lp);
							} catch (Exception ignore) {
								// 拖动过程中偶尔会被系统拦一下 → 忽略，下一帧还会接着动 ✓
							}
						}
						return true;
					case MotionEvent.ACTION_UP:
						// 松手回到原大小 ✓（阶段 12：拖动时她就是"被捏小"的样子 ✓）
						v.animate().scaleX(1f).scaleY(1f).setDuration(150).start();
						if (moved) {
							// 阶段 13：松手**吸附到最近的屏幕边** ✓ ——
							// 拖到哪算哪的话，球总停在屏幕当间挡着你看东西 ✗；
							// 靠边站既少挡视线 ✓，下次伸手也好找 ✓（这是手机上悬浮球的老规矩 ✓）
							snapToEdge(v);
						} else {
							long now = System.currentTimeMillis();
							if (now - lastTapMs <= DOUBLE_TAP_MS) {
								// 双击 = 截一张屏给她看 ✓（阶段 11）——
								// 先把面板收掉 ✓：截的是**整个屏幕** ✓，面板开着会被一起拍进去 ✗
								//（阶段 13 起：开了无障碍就**不弹系统授权框**了 ✓；
								//  没开才回退到那个框 ✓，那时候面板也会压在被点的那块上 ✓）
								lastTapMs = 0L;
								if (panel != null) {
									hidePanel();
								}
								squash(v);      // 先"缩一下"再弹回来 ✓（双击的动画反馈 ✓）
								Log.i(TAG, "悬浮球: 双击 → 截一张屏给她看 ✓");
								PetShot.request(activity);
							} else {
								lastTapMs = now;
								togglePanel();  // 点一下 = 弹出小聊天面板 ✓（想回 App 面板里有按钮 ✓）
							}
						}
						return true;
					default:
						return false;
				}
			}
		});

		GradientDrawable outer = new GradientDrawable();
		outer.setShape(GradientDrawable.OVAL);
		outer.setColor(Color.TRANSPARENT);
		iv.setForeground(outer);          // 描边叠在最上层 ✓（头像在上面也看得见边 ✓）
		wm.addView(iv, p);
		ball = iv;
		ballIv = iv;
		startFrames(activity, iv);        // 阶段 12：会眨眼、会微微晃 ✓（没帧序列就还是静止那张 ✓）
	}

	private static void openApp() {
		try {
			Intent open = activity.getPackageManager()
					.getLaunchIntentForPackage(activity.getPackageName());
			if (open != null) {
				open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
				activity.startActivity(open);
			}
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 打开 App 失败 " + e);
		}
	}

	/** 读那张**静止**的脸（Java 侧兜底 ✓）：缩到球大小 + 裁成圆形 ✓ */
	private static Bitmap loadFace(Context c) {
		return loadOne(c, FACE_FILE);
	}

	/** 缩到球大小 + 裁成圆形 ✓ —— 阶段 12 起，帧序列的每一张也走它 ✓
	 *  （方形头像直接拿来当球会很怪 ✗，所以不管几张都得裁 ✓） */
	private static Bitmap circleMask(Bitmap src, int want) {
		Bitmap scaled = Bitmap.createScaledBitmap(src, want, want, true);
		Bitmap out = Bitmap.createBitmap(want, want, Bitmap.Config.ARGB_8888);
		android.graphics.Canvas cv = new android.graphics.Canvas(out);
		android.graphics.Paint pt = new android.graphics.Paint(
				android.graphics.Paint.ANTI_ALIAS_FLAG);
		cv.drawCircle(want / 2f, want / 2f, want / 2f - 1f, pt);
		pt.setXfermode(new android.graphics.PorterDuffXfermode(
				android.graphics.PorterDuff.Mode.SRC_IN));
		cv.drawBitmap(scaled, 0f, 0f, pt);
		if (scaled != src) {
			scaled.recycle();
		}
		return out;
	}

	// ---- 阶段 12：一串帧 —— 会眨眼、会微微晃 ✓ ----

	/** 把帧序列读进来、开播 ✓（读不到就什么都不做 ✓ —— 球上还留着那张静止的她 ✓） */
	private static void startFrames(Context c, ImageView iv) {
		stopFrames();
		idleFrames = loadFrames(c, FACE_FRAME_TMPL, FACE_MAX_FRAMES);
		if (idleFrames.length < 2) {
			idleFrames = null;
			Log.i(TAG, "悬浮球: 没读到帧序列 → 球就是静止那张 ✓");
			return;
		}
		// 每帧停多久：GDScript 按**待机动画一整圈**算好的 ✓（一圈首尾相接 ✓，循环不跳 ✓）
		idleDwell = readDwell(c);
		// 眨眼那三下：半闭 → 闭 → 半闭 ✓（凑不齐就不眨 ✓，绝不硬编 ✗）
		Bitmap half = loadOne(c, FACE_BLINK_HALF);
		Bitmap shut = loadOne(c, FACE_BLINK_CLOSED);
		if (half != null && shut != null) {
			blinkSeq = new Bitmap[] { half, shut, half };   // 同一张对象存两次 ✓（recycle 是幂等的 ✓）
		} else {
			if (half != null) {
				half.recycle();
			}
			if (shut != null) {
				shut.recycle();
			}
			blinkSeq = null;
		}
		idleIdx = 0;
		idleDir = 1;
		blinkStep = -1;
		anim.postDelayed(frameTick, idleDwell);
		anim.postDelayed(blinkTick, BLINK_MIN_MS + (long) (Math.random() * BLINK_SPAN_MS));
		Log.i(TAG, "悬浮球: 帧序列开播 ✓（待机 " + idleFrames.length + " 帧 ｜ 每帧 " + idleDwell
				+ "ms ｜ 眨眼 " + (blinkSeq == null ? "没凑齐 ✗" : "3 帧 ✓") + "）");
	}

	/** 收摊：撤掉回调 + 放掉位图 ✓（球一收就得放 ✗，不然每开一次球都多留一份内存 ✓） */
	private static void stopFrames() {
		anim.removeCallbacks(frameTick);
		anim.removeCallbacks(blinkTick);
		blinkStep = -1;
		if (idleFrames != null) {
			for (Bitmap b : idleFrames) {
				if (b != null) {
					b.recycle();
				}
			}
			idleFrames = null;
		}
		if (blinkSeq != null) {
			for (Bitmap b : blinkSeq) {
				if (b != null) {
					b.recycle();
				}
			}
			blinkSeq = null;
		}
	}

	/** 帧轮播 ✓（球一没就自己停 ✗ —— 不然会往一个已经不在屏幕上的 View 上贴帧 ✓） */
	private static final Runnable frameTick = new Runnable() {
		@Override
		public void run() {
			if (ballIv == null || idleFrames == null) {
				return;
			}
			if (blinkStep >= 0 && blinkSeq != null) {
				if (blinkStep < blinkSeq.length) {
					ballIv.setImageBitmap(blinkSeq[blinkStep]);
					// 闭着那一下多停一点 ✓：真人闭眼比睁眼慢些 ✓，太快就像画面在闪 ✗
					long d = (blinkStep == 1) ? 90L : 60L;
					blinkStep++;
					anim.postDelayed(this, d);
					return;
				}
				blinkStep = -1;
				anim.postDelayed(this, idleDwell);
				return;
			}
			// ⚠️ **往返播**（2026-10-10）：她那一圈待机动画有 **24 秒** ✓，
			//   我们只截了前 2.4 秒 ✓ —— 首尾相接直接循环的话，
			//   每 2.4 秒会"啪"地跳回开头一次 ✗（球虽小，看得出来 ✓）。
			//   往返播**两端天然对得上** ✓：0→5→0 ✓，接缝处根本不用换姿势 ✓
			ballIv.setImageBitmap(idleFrames[idleIdx]);
			if (idleFrames.length > 2) {
				idleIdx += idleDir;
				if (idleIdx >= idleFrames.length) {
					idleIdx = idleFrames.length - 2;
					idleDir = -1;
				} else if (idleIdx < 0) {
					idleIdx = 1;
					idleDir = 1;
				}
			} else {
				idleIdx = (idleIdx + 1) % idleFrames.length;
			}
			anim.postDelayed(this, idleDwell);
		}
	};

	/** 隔一阵眨一次 ✓（间隔**随机** ✓ —— 准点眨看着像机器 ✗） */
	private static final Runnable blinkTick = new Runnable() {
		@Override
		public void run() {
			if (ballIv == null || idleFrames == null) {
				return;
			}
			if (blinkSeq != null) {
				blinkStep = 0;
			}
			anim.postDelayed(this, BLINK_MIN_MS + (long) (Math.random() * BLINK_SPAN_MS));
		}
	};

	/** 读清单里的"每帧毫秒" ✓（读不到就 200ms ✓；夹在 60~600 ✓，免得哪天数错一位她就抽风 ✗） */
	private static int readDwell(Context c) {
		try {
			File f = new File(c.getFilesDir(), FACE_MANIFEST);
			if (!f.exists()) {
				return 200;
			}
			java.io.BufferedReader r = new java.io.BufferedReader(
					new java.io.InputStreamReader(new java.io.FileInputStream(f), "UTF-8"));
			String line = r.readLine();
			r.close();
			if (line == null) {
				return 200;
			}
			String[] parts = line.trim().split("\\s+");
			if (parts.length >= 2) {
				return Math.max(60, Math.min(600, Integer.parseInt(parts[1])));
			}
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 清单读不动 " + e);
		}
		return 200;
	}

	/** 连续读一串帧 ✓（第 i 张按模板拼 ✓；**缺一张就停** ✓ —— 断掉的序列不播 ✗） */
	private static Bitmap[] loadFrames(Context c, String tmpl, int max) {
		ArrayList<Bitmap> out = new ArrayList<>();
		for (int i = 0; i < max; i++) {
			Bitmap b = loadOne(c, String.format(tmpl, i));
			if (b == null) {
				break;
			}
			out.add(b);
		}
		return out.toArray(new Bitmap[0]);
	}

	/** 读一张（解码 → 裁圆 → 放掉原图 ✓）；读不到就 null ✓ */
	private static Bitmap loadOne(Context c, String name) {
		try {
			File f = new File(c.getFilesDir(), name);
			if (!f.exists()) {
				return null;
			}
			Bitmap src = BitmapFactory.decodeFile(f.getAbsolutePath());
			if (src == null) {
				return null;
			}
			Bitmap out = circleMask(src, dp(c, BALL_DP));
			src.recycle();
			return out;
		} catch (Exception e) {
			Log.e(TAG, "悬浮球: 读帧失败 " + name + " " + e);
			return null;
		}
	}

	/** "双击缩一下"✓：先捏小 ✓ → 弹大一点 ✓ → 回原样 ✓ */
	private static void squash(View v) {
		v.animate().scaleX(0.80f).scaleY(0.80f).setDuration(70).withEndAction(new Runnable() {
			@Override
			public void run() {
				v.animate().scaleX(1.10f).scaleY(1.10f).setDuration(120)
						.withEndAction(new Runnable() {
							@Override
							public void run() {
								v.animate().scaleX(1f).scaleY(1f).setDuration(90).start();
							}
						}).start();
			}
		}).start();
	}

	/** 气泡：一块圆角半透明的板子 + 她那句话 ✓ */
	private static View buildBubble(Context c, String text) {
		LinearLayout box = new LinearLayout(c);
		GradientDrawable g = new GradientDrawable();
		g.setShape(GradientDrawable.RECTANGLE);
		g.setCornerRadius(dp(c, 14));
		g.setColor(Color.parseColor("#E61B2430"));
		g.setStroke(dp(c, 1), Color.parseColor("#66FFFFFF"));
		box.setBackground(g);
		box.setPadding(dp(c, 12), dp(c, 8), dp(c, 12), dp(c, 8));
		TextView tv = new TextView(c);
		tv.setText(text);
		tv.setTextColor(Color.parseColor("#FFF2F6FF"));
		tv.setTextSize(14f);
		tv.setMaxWidth(dp(c, 220));
		box.addView(tv);              // ⚠️ 是 addView ✓（LinearLayout 没有 addChild ✗）
		return box;
	}

	private static WindowManager.LayoutParams bubbleParams(Context c, String text) {
		WindowManager.LayoutParams p = new WindowManager.LayoutParams(
				WindowManager.LayoutParams.WRAP_CONTENT,
				WindowManager.LayoutParams.WRAP_CONTENT,
				overlayType(),
				WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
						| WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
				PixelFormat.TRANSLUCENT);
		p.gravity = Gravity.TOP | Gravity.START;
		// ⚠️ 阶段 13 改了摆法 ✗→✓：原来**固定贴球右边** ✓，球一旦靠近右边缘
		//    气泡就会被屏幕裁掉半截 ✗（"她又说话了，可看不全"✓）。
		//    现在：右边放不下就摆到**球的左边** ✓，再整体夹进屏幕 ✓
		android.util.DisplayMetrics dm = c.getResources().getDisplayMetrics();
		int ball = dp(c, BALL_DP);
		int gap = dp(c, 6);
		int pad = dp(c, 24);
		// 估个宽度：中文按 15dp/字、最多 220dp ✓（估不准也不怕 —— 下面还会夹一次 ✓）
		int estW = Math.min(dp(c, 220), Math.max(1, text.length()) * dp(c, 15)) + pad;
		int rightX = ballX + ball + gap;
		int leftX = ballX - gap - estW;
		int x = rightX;
		if (rightX + estW > dm.widthPixels && leftX >= 0) {
			x = leftX;                   // 右边放不下 → 挪到球左边 ✓
		}
		p.x = Math.max(0, Math.min(x, Math.max(0, dm.widthPixels - estW)));
		// 竖直：和球顶大致对齐 ✓，但别越过屏幕下沿 ✓（气泡都是一句话，按单行估高就够 ✓）
		int estH = dp(c, 44);
		p.y = Math.max(0, Math.min(ballY, Math.max(0, dm.heightPixels - estH)));
		return p;
	}
}
