package com.godot.game;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * 阶段 10（2026-10-09）：悬浮窗里"打字跟她说一句"的那个**一次性请求**。
 *
 * 为什么聊天要在 Java 里做（而不是交给 Godot）✗：
 *   引擎的主循环在后台是**停的** ✓（阶段 9 实测：心率一次都没打 ✓），
 *   所以我敲进去的字送不回 GDScript ✓。那就只能这边直接调模型 ✓。
 *
 * ⚠️ 人设**不在这边编** ✗ —— GDScript 在退后台那一刻写好一份快照
 *   （`files/overlay_prompt.txt` ✓ = 系统提示词 + 最近几句 + 现在几点 ✓），
 *   这里只负责读它、当 system 消息发出去 ✓。这样"她是谁"只有一处定义 ✓，两边话风不会漂 ✓。
 *
 * 读的东西（都在应用私有目录 ✓）：
 *   · `files/pet_mobile.cfg`       —— 后端地址 / 模型（Godot 的 ConfigFile 格式 ✓ 就是 INI ✓）
 *   · `files/pet_secret_mobile.dat` —— 明文密钥（Godot 那边就是这么存的 ✓）
 *   · `files/overlay_prompt.txt`   —— 人设快照 ✓
 *
 * 请求是**开一条线程**做的 ✓（悬浮窗是 UI 线程 ✓，不能卡它 ✗），回调也在那条线程上 ✓
 * —— 调用方（PetOverlay）自己 post 回 UI 线程 ✓。
 */
public class PetChatOnce {
	private static final String TAG = "GODOT";

	/** 一句话的结果 ✓：成 / 不成（不成也要给她个说法 ✓） */
	public interface Cb {
		void ok(String reply);
		void fail(String why);
	}

	public static void send(final Context ctx, final String userText, final String historyBlock, final Cb cb) {
		new Thread(new Runnable() {
			@Override
			public void run() {
				String reply = null;
				String why = null;
				try {
					String base = readCfg(ctx, "chat", "url", "https://api.deepseek.com").trim();
					String model = readCfg(ctx, "chat", "model", "deepseek-flash").trim();
					String key = readText(new File(ctx.getFilesDir(), "pet_secret_mobile.dat"), 512).trim();
					String persona = readText(new File(ctx.getFilesDir(), "overlay_prompt.txt"), 8000);
					if (base.isEmpty()) {
						base = "https://api.deepseek.com";
					}
					if (persona.trim().isEmpty()) {
						// 快照没写成也不至于答不出话 ✓ —— 给一句最朴素的交代 ✓
						persona = "你是主人的手机桌宠。用你自己的口气、一两句回他。";
					}
					JSONArray msgs = new JSONArray();
					msgs.put(new JSONObject().put("role", "system").put("content", persona));
					if (historyBlock != null && !historyBlock.trim().isEmpty()) {
						msgs.put(new JSONObject().put("role", "user")
								.put("content", "【刚才在悬浮窗里聊过这些】\n" + historyBlock));
					}
					msgs.put(new JSONObject().put("role", "user").put("content", userText));
					JSONObject body = new JSONObject();
					body.put("model", model.isEmpty() ? "deepseek-flash" : model);
					body.put("messages", msgs);
					body.put("stream", false);

					String url = endpoint(base);
					HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
					c.setRequestMethod("POST");
					c.setConnectTimeout(15000);
					c.setReadTimeout(90000);
					c.setDoOutput(true);
					c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
					if (!key.isEmpty()) {
						c.setRequestProperty("Authorization", "Bearer " + key);
					}
					byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
					try (OutputStream os = c.getOutputStream()) {
						os.write(payload);
					}
					int code = c.getResponseCode();
					InputStream is = (code >= 400) ? c.getErrorStream() : c.getInputStream();
					String raw = readAll(is);
					Log.i(TAG, "悬浮窗聊天: HTTP " + code + " ｜ 回来 " + raw.length() + " 字节");
					if (code >= 400) {
						why = "HTTP " + code + "：" + clip(raw, 120);
					} else {
						JSONObject jo = new JSONObject(raw);
						reply = jo.getJSONArray("choices").getJSONObject(0)
								.getJSONObject("message").getString("content");
						if (reply == null || reply.trim().isEmpty()) {
							reply = null;
							why = "模型返回是空的（思考型模型有时会这样 ✓ 再问一次就好）";
						}
					}
				} catch (Exception e) {
					why = String.valueOf(e);
				}
				if (reply != null && !reply.trim().isEmpty()) {
					if (cb != null) {
						cb.ok(reply.trim());
					}
				} else if (cb != null) {
					cb.fail(why == null ? "未知原因" : why);
				}
			}
		}, "PetChatOnce").start();
	}

	/** 拼出 chat completions 的地址 ✓（三种写法都容得下 ✓：带 /chat/completions、带 /v1、光一个域名 ✓） */
	private static String endpoint(String base) {
		String b = base.replaceAll("/+$", "");
		if (b.endsWith("/chat/completions")) {
			return b;
		}
		if (b.endsWith("/v1")) {
			return b + "/chat/completions";
		}
		return b + "/v1/chat/completions";
	}

	/** 读 Godot 那份 ConfigFile 里的一个值 ✓（它就是 INI ✓；值可能带双引号 ✓ 要去掉 ✓） */
	private static String readCfg(Context ctx, String section, String key, String def) {
		try {
			File f = new File(ctx.getFilesDir(), "pet_mobile.cfg");
			if (!f.exists()) {
				return def;
			}
			String cur = "";
			for (String line : readText(f, 20000).split("\n")) {
				String s = line.trim();
				if (s.isEmpty() || s.startsWith(";") || s.startsWith("#")) {
					continue;
				}
				if (s.startsWith("[") && s.endsWith("]")) {
					cur = s.substring(1, s.length() - 1).trim();
					continue;
				}
				int eq = s.indexOf('=');
				if (eq <= 0 || !cur.equals(section)) {
					continue;
				}
				if (s.substring(0, eq).trim().equals(key)) {
					String v = s.substring(eq + 1).trim();
					if (v.length() >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
						v = v.substring(1, v.length() - 1);
					}
					return v;
				}
			}
		} catch (Exception e) {
			Log.e(TAG, "悬浮窗聊天: 读配置失败 " + e);
		}
		return def;
	}

	private static String readText(File f, int max) {
		try {
			if (!f.exists()) {
				return "";
			}
			return readAll(new FileInputStream(f), max);
		} catch (Exception e) {
			return "";
		}
	}

	private static String readAll(InputStream is) throws Exception {
		return readAll(is, 1 << 20);
	}

	private static String readAll(InputStream is, int max) throws Exception {
		if (is == null) {
			return "";
		}
		StringBuilder sb = new StringBuilder();
		try (BufferedReader r = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
			char[] buf = new char[4096];
			int n;
			while ((n = r.read(buf)) > 0 && sb.length() < max) {
				sb.append(buf, 0, n);
			}
		}
		return sb.toString();
	}

	private static String clip(String s, int n) {
		if (s == null) {
			return "";
		}
		String t = s.replace("\n", " ").trim();
		return t.length() <= n ? t : t.substring(0, n) + "…";
	}
}
