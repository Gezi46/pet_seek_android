/**************************************************************************/
/*  GodotApp.java                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 */
public class GodotApp extends GodotActivity {
	static {
		// .NET libraries.
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen splashScreen = SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);
		// 阶段 5c 追加：把 Activity 交给那座小桥（GDScript 侧要用它拉起"选相册图" ✓）
		PetBridge.setActivity(this);
		// 阶段 5c：可能是"分享图片"把应用拉起来的 ✓（那时 Intent 就在这）
		receiveSharedImage(getIntent());

		Godot godot = getGodot();
		if (godot != null && godot.getDisableGodotSplash()) {
			splashScreen.setKeepOnScreenCondition(() -> godot.getRunStatus() != Godot.RunStatus.STARTED);
		}
	}

	/** 阶段 5c（2026-10-09）：系统分享进来的图片，落到 files/share_in.jpg 里。
	 *
	 * 为什么要在 Java 这侧落盘、让 GDScript 去轮询它：
	 *   ① Godot 没有"接收外部 Intent"的 API ✗（没有回调、也拿不到 getIntent ✓）；
	 *   ② 分享过来的是 content:// URI，它的字节 GDScript 读不到 ✗（不是普通文件路径 ✓）。
	 * 所以这里把字节复制进应用私有目录（= GDScript 的 user:// ✓），
	 * 那边只要看 user://share_in.jpg 在不在就行 ✓ —— 不用 JNI、不用插件信号 ✓。
	 *
	 * 先写 .part 再改名：否则她可能读到**写了一半**的图 ✗（大图要几百毫秒 ✓）。
	 */
	private void receiveSharedImage(Intent intent) {
		if (intent == null || !Intent.ACTION_SEND.equals(intent.getAction())) {
			return;
		}
		String type = intent.getType();
		if (type == null || !type.startsWith("image/")) {
			return;                     // 只收图片；文本先不管 ✓
		}
		Uri uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
		if (uri == null) {
			return;
		}
		// 落盘那一段和"应用内从相册选图"共用（PetBridge.copyToShareIn ✓）——
		// 两个入口各写一份的话，哪天改歪一个就难查了 ✗
		PetBridge.copyToShareIn(uri, type);
	}

	/** 应用已经在跑着时又分享进来一张图（manifest 里 launchMode 是 singleInstancePerTask ✓） */
	@Override
	public void onNewIntent(Intent intent) {
		super.onNewIntent(intent);
		setIntent(intent);
		receiveSharedImage(intent);
	}

	/** 阶段 5c 追加：应用内"从相册选一张给她"的结果回到这里 ✓
	 *  ⚠️ `super` 一定要调：引擎（以及将来任何插件）的 onActivityResult 得照常走一遍 ✓ */
	@Override
	protected void onActivityResult(int requestCode, int resultCode, Intent data) {
		super.onActivityResult(requestCode, resultCode, data);
		PetBridge.handleActivityResult(requestCode, resultCode, data);
		PetShot.handleActivityResult(requestCode, resultCode, data);   // 阶段 11：截屏授权 ✓
	}

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
	}

	@Override
	public void onGodotMainLoopStarted() {
		super.onGodotMainLoopStarted();
		runOnUiThread(updateWindowAppearance);
	}

	@Override
	public void onGodotForceQuit(Godot instance) {
		if (!BuildConfig.FLAVOR.equals("instrumented")) {
			// For instrumented builds, we disable force-quitting to allow the instrumented tests to complete
			// successfully, otherwise they fail when the process crashes.
			super.onGodotForceQuit(instance);
		}
	}

	@Override
	protected boolean isPiPEnabled() {
		return true;
	}
}
