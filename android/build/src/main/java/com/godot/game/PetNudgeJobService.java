package com.godot.game;

import android.app.job.JobParameters;
import android.app.job.JobService;
import android.util.Log;

/**
 * 阶段 9b（2026-10-09）：到点"喊一声"的那个 Job。
 *
 * 为什么不用 AlarmManager ✗（这是真机上撞出来的钉子 ✓）：
 *   闹钟确实排进了系统 ✓（`dumpsys alarm` 里看得见 ✓），但到点却**一直不投** ✗ ——
 *   `dumpsys alarm` 的历史里写着：
 *       `Reason=frozen ... app_standby=-2m9s920ms battery_saver=-2m1s336ms`
 *   也就是：应用退到后台之后会被安卓 11+ 的 **app freezer 冻住** ✓，
 *   而**被冻结的应用，它的闹钟会被系统押着不投** ✗（连 inexact 的 while-idle 也一样 ✓）。
 *
 *   要让它解冻只有两条路：
 *     · 挂一条前台服务不让它进 cached ✓ —— 可那条我们已经实测过：救不活主循环 ✓，
 *       而且要在你手机上常驻一条通知 ✗（阶段 9 的结论 ✓）；
 *     · **改用 JobScheduler** ✓ —— 这一条是框架级的保证：Job 到点会把冻结的应用唤醒 ✓✓
 *       （系统自己 unfreeze + 投递 ✓）。不需要任何第三方库 ✓（framework API ✓）。
 *
 * 所以：到点这个 Job 起来 → 交给 `PetNotifyReceiver.fireOnce` ✓（取一句台词 + 发通知 ✓），
 * 干完就 `return false` ✓（不占 wakelock ✓，也不要系统重排 ✓）。
 */
public class PetNudgeJobService extends JobService {
	private static final String TAG = "GODOT";

	@Override
	public boolean onStartJob(JobParameters params) {
		Log.i(TAG, "喊一声: Job 到点了（jobId=" + params.getJobId() + "）");
		PetNotifyReceiver.fireOnce(this);
		return false;      // 同步干完了 ✓ —— 返回 true 就得自己再调 jobFinished ✗，这里不需要 ✓
	}

	@Override
	public boolean onStopJob(JobParameters params) {
		return false;      // 被系统掐了就别重排 ✓（她现在不该追着你喊 ✗）
	}
}
