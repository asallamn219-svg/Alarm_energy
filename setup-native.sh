#!/bin/bash
# يضيف محرك المنبه الأصلي لمشروع أندرويد بعد cap add android
set -e
D=$(dirname "$(find android/app/src/main/java -name MainActivity.java | head -n 1)")
echo "Java dir: $D"

cat > "$D/MainActivity.java" <<'EOF'
package com.asallam.alarmenergy;

import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    registerPlugin(NativeAlarmPlugin.class);
    super.onCreate(savedInstanceState);
    over(getIntent());
  }

  @Override
  protected void onNewIntent(Intent intent) {
    super.onNewIntent(intent);
    over(intent);
  }

  private void over(Intent in) {
    if (in != null && in.getBooleanExtra("alarm", false)) {
      if (Build.VERSION.SDK_INT >= 27) {
        setShowWhenLocked(true);
        setTurnScreenOn(true);
      } else {
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
      }
      getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
  }
}
EOF

cat > "$D/AlarmStore.java" <<'EOF'
package com.asallam.alarmenergy;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;

public class AlarmStore {
  static SharedPreferences sp(Context c) {
    return c.getSharedPreferences("alarm_store", Context.MODE_PRIVATE);
  }

  static JSONArray load(Context c) {
    try {
      return new JSONArray(sp(c).getString("list", "[]"));
    } catch (Exception e) {
      return new JSONArray();
    }
  }

  static void save(Context c, JSONArray a) {
    sp(c).edit().putString("list", a.toString()).apply();
  }

  static PendingIntent pi(Context c, int id, String label, String time) {
    Intent i = new Intent(c, AlarmReceiver.class);
    i.setAction("com.asallam.alarmenergy.FIRE");
    i.putExtra("id", id);
    i.putExtra("label", label);
    i.putExtra("time", time);
    return PendingIntent.getBroadcast(c, id, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
  }

  static void setOne(Context c, int id, long at, String label, String time) {
    AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
    Intent show = new Intent(c, MainActivity.class);
    PendingIntent sh = PendingIntent.getActivity(c, 0, show, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    am.setAlarmClock(new AlarmManager.AlarmClockInfo(at, sh), pi(c, id, label, time));
  }

  static void cancelAll(Context c) {
    AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
    JSONArray a = load(c);
    for (int i = 0; i < a.length(); i++) {
      JSONObject o = a.optJSONObject(i);
      if (o == null) continue;
      am.cancel(pi(c, o.optInt("id"), "", ""));
    }
  }

  static void scheduleAll(Context c, JSONArray list) {
    cancelAll(c);
    JSONArray keep = new JSONArray();
    long now = System.currentTimeMillis();
    for (int i = 0; i < list.length(); i++) {
      JSONObject o = list.optJSONObject(i);
      if (o == null) continue;
      long at = o.optLong("at");
      boolean wk = o.optBoolean("weekly");
      if (wk) {
        while (at <= now) at += 604800000L;
        try {
          o.put("at", at);
        } catch (Exception e) {
        }
      }
      if (at <= now) continue;
      keep.put(o);
      setOne(c, o.optInt("id"), at, o.optString("label"), o.optString("time"));
    }
    save(c, keep);
  }

  static void rescheduleFromStore(Context c) {
    scheduleAll(c, load(c));
  }
}
EOF

cat > "$D/AlarmReceiver.java" <<'EOF'
package com.asallam.alarmenergy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import androidx.core.content.ContextCompat;
import org.json.JSONArray;
import org.json.JSONObject;

public class AlarmReceiver extends BroadcastReceiver {
  @Override
  public void onReceive(Context c, Intent in) {
    int id = in.getIntExtra("id", 0);
    String label = in.getStringExtra("label");
    String time = in.getStringExtra("time");
    try {
      JSONArray a = AlarmStore.load(c);
      for (int i = 0; i < a.length(); i++) {
        JSONObject o = a.getJSONObject(i);
        if (o.optInt("id") == id && o.optBoolean("weekly")) {
          long at = o.optLong("at");
          long now = System.currentTimeMillis();
          while (at <= now) at += 604800000L;
          o.put("at", at);
          AlarmStore.save(c, a);
          AlarmStore.setOne(c, id, at, o.optString("label"), o.optString("time"));
        }
      }
    } catch (Exception e) {
    }
    Intent s = new Intent(c, AlarmService.class);
    s.putExtra("label", label == null ? "" : label);
    s.putExtra("time", time == null ? "" : time);
    ContextCompat.startForegroundService(c, s);
  }
}
EOF

cat > "$D/BootReceiver.java" <<'EOF'
package com.asallam.alarmenergy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
  @Override
  public void onReceive(Context c, Intent in) {
    try {
      AlarmStore.rescheduleFromStore(c);
    } catch (Exception e) {
    }
  }
}
EOF

cat > "$D/AlarmService.java" <<'EOF'
package com.asallam.alarmenergy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.VibrationEffect;
import android.os.Vibrator;
import androidx.core.app.NotificationCompat;
import java.io.File;

public class AlarmService extends Service {
  static AlarmService inst;
  static boolean ringing = false;
  static String rLabel = "";
  static String rTime = "";

  private MediaPlayer mp;
  private Vibrator vib;
  private PowerManager.WakeLock wl;
  private final Handler h = new Handler(Looper.getMainLooper());
  private Runnable loopCk;
  private final Runnable autoStop = new Runnable() {
    @Override
    public void run() {
      stopAlarm();
    }
  };

  @Override
  public IBinder onBind(Intent i) {
    return null;
  }

  @Override
  public void onCreate() {
    super.onCreate();
    inst = this;
  }

  @Override
  public int onStartCommand(Intent in, int flags, int startId) {
    String act = in == null ? null : in.getAction();
    if ("STOP".equals(act)) {
      stopAlarm();
      return START_NOT_STICKY;
    }
    if ("SNOOZE".equals(act)) {
      snooze();
      return START_NOT_STICKY;
    }
    String label = in == null ? null : in.getStringExtra("label");
    String time = in == null ? null : in.getStringExtra("time");
    begin(label == null ? "" : label, time == null ? "" : time);
    return START_NOT_STICKY;
  }

  private void begin(String label, String time) {
    inst = this;
    stopSound();
    ringing = true;
    rLabel = label;
    rTime = time;

    NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= 26) {
      NotificationChannel ch = new NotificationChannel("alarm_ring", "المنبه الجاري", NotificationManager.IMPORTANCE_HIGH);
      ch.setSound(null, null);
      ch.enableVibration(false);
      ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
      nm.createNotificationChannel(ch);
    }

    Intent open = new Intent(this, MainActivity.class);
    open.putExtra("alarm", true);
    open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    PendingIntent openPi = PendingIntent.getActivity(this, 11, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

    Intent st = new Intent(this, AlarmService.class);
    st.setAction("STOP");
    PendingIntent stPi = PendingIntent.getService(this, 12, st, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    Intent sn = new Intent(this, AlarmService.class);
    sn.setAction("SNOOZE");
    PendingIntent snPi = PendingIntent.getService(this, 13, sn, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

    Notification n = new NotificationCompat.Builder(this, "alarm_ring")
        .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
        .setContentTitle(label.isEmpty() ? "منبه" : label)
        .setContentText(time.isEmpty() ? "اصحى!" : time)
        .setCategory(NotificationCompat.CATEGORY_ALARM)
        .setPriority(NotificationCompat.PRIORITY_MAX)
        .setOngoing(true)
        .setContentIntent(openPi)
        .setFullScreenIntent(openPi, true)
        .addAction(0, "غفوة 5 دقايق", snPi)
        .addAction(0, "إيقاف", stPi)
        .build();

    if (Build.VERSION.SDK_INT >= 29) {
      startForeground(77, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
    } else {
      startForeground(77, n);
    }

    PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
    wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "alarmenergy:ring");
    wl.acquire(10 * 60 * 1000L);

    play();
    vibrate();
    h.postDelayed(autoStop, 10 * 60 * 1000L);
    NativeAlarmPlugin.emit("ringing", label, time);
  }

  private AudioAttributes alarmAttrs() {
    return new AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build();
  }

  private Uri defaultUri() {
    Uri u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
    if (u == null) u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
    if (u == null) u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
    return u;
  }

  private void play() {
    try {
      File f = new File(getFilesDir(), "tone.bin");
      SharedPreferences p = AlarmStore.sp(this);
      final int s = (int) (p.getFloat("ts", 0f) * 1000);
      final int e = (int) (p.getFloat("te", 0f) * 1000);
      final boolean custom = f.exists() && f.length() > 0;
      final boolean clip = custom && e > s;

      mp = new MediaPlayer();
      mp.setAudioAttributes(alarmAttrs());
      if (custom) {
        mp.setDataSource(f.getAbsolutePath());
      } else {
        mp.setDataSource(this, defaultUri());
      }
      mp.setLooping(!clip);
      if (clip) {
        mp.setOnCompletionListener(m -> {
          try {
            m.seekTo(s);
            m.start();
          } catch (Exception x1) {
          }
        });
      }
      mp.setOnErrorListener((m, what, extra) -> {
        playDefault();
        return true;
      });
      mp.setOnPreparedListener(m -> {
        try {
          if (clip) m.seekTo(s);
          m.start();
          if (clip) {
            loopCk = new Runnable() {
              @Override
              public void run() {
                try {
                  if (mp != null && mp.isPlaying() && mp.getCurrentPosition() >= e - 40) {
                    mp.seekTo(s);
                  }
                } catch (Exception x2) {
                }
                h.postDelayed(this, 40);
              }
            };
            h.postDelayed(loopCk, 40);
          }
        } catch (Exception x3) {
        }
      });
      mp.prepareAsync();
    } catch (Exception ex) {
      playDefault();
    }
  }

  private void playDefault() {
    try {
      if (loopCk != null) h.removeCallbacks(loopCk);
      if (mp != null) {
        try {
          mp.release();
        } catch (Exception x4) {
        }
        mp = null;
      }
      mp = new MediaPlayer();
      mp.setAudioAttributes(alarmAttrs());
      mp.setDataSource(this, defaultUri());
      mp.setLooping(true);
      mp.setOnPreparedListener(m -> m.start());
      mp.prepareAsync();
    } catch (Exception x5) {
    }
  }

  private void vibrate() {
    try {
      vib = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
      long[] pat = new long[] {0, 700, 500};
      if (Build.VERSION.SDK_INT >= 26) {
        vib.vibrate(VibrationEffect.createWaveform(pat, 0), alarmAttrs());
      } else {
        vib.vibrate(pat, 0);
      }
    } catch (Exception x6) {
    }
  }

  private void stopSound() {
    if (loopCk != null) h.removeCallbacks(loopCk);
    if (mp != null) {
      try {
        mp.stop();
      } catch (Exception x7) {
      }
      try {
        mp.release();
      } catch (Exception x8) {
      }
      mp = null;
    }
    if (vib != null) {
      try {
        vib.cancel();
      } catch (Exception x9) {
      }
    }
    if (wl != null && wl.isHeld()) {
      try {
        wl.release();
      } catch (Exception x10) {
      }
    }
  }

  void snooze() {
    long now = System.currentTimeMillis();
    int id = 1000000000 + (int) ((now / 1000) % 100000000L);
    String l = rLabel.isEmpty() ? "منبه" : rLabel;
    AlarmStore.setOne(this, id, now + 5 * 60 * 1000L, l + " (غفوة)", rTime);
    stopAlarm();
  }

  void stopAlarm() {
    stopSound();
    h.removeCallbacks(autoStop);
    ringing = false;
    try {
      stopForeground(true);
    } catch (Exception x11) {
    }
    stopSelf();
    NativeAlarmPlugin.emit("stopped", rLabel, rTime);
  }

  static void stopNow() {
    if (inst != null) inst.stopAlarm();
  }

  @Override
  public void onDestroy() {
    stopSound();
    ringing = false;
    inst = null;
    super.onDestroy();
  }
}
EOF

cat > "$D/NativeAlarmPlugin.java" <<'EOF'
package com.asallam.alarmenergy;

import android.content.Intent;
import android.util.Base64;
import androidx.core.content.ContextCompat;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.File;
import java.io.FileOutputStream;

@CapacitorPlugin(name = "NativeAlarm")
public class NativeAlarmPlugin extends Plugin {
  static NativeAlarmPlugin inst;

  @Override
  public void load() {
    inst = this;
  }

  @Override
  protected void handleOnDestroy() {
    if (inst == this) inst = null;
  }

  static void emit(String ev, String label, String time) {
    try {
      if (inst != null) {
        JSObject o = new JSObject();
        o.put("label", label);
        o.put("time", time);
        inst.notifyListeners(ev, o);
      }
    } catch (Throwable t) {
    }
  }

  @PluginMethod
  public void schedule(PluginCall call) {
    try {
      JSArray arr = call.getArray("alarms");
      if (arr == null) arr = new JSArray();
      AlarmStore.scheduleAll(getContext(), arr);
      call.resolve();
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void toneChunk(PluginCall call) {
    try {
      byte[] b = Base64.decode(call.getString("b64"), Base64.DEFAULT);
      boolean first = Boolean.TRUE.equals(call.getBoolean("first", false));
      File f = new File(getContext().getFilesDir(), "tone.bin");
      FileOutputStream o = new FileOutputStream(f, !first);
      o.write(b);
      o.close();
      call.resolve();
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void toneClip(PluginCall call) {
    try {
      Double s = call.getDouble("start", 0.0);
      Double en = call.getDouble("end", 0.0);
      AlarmStore.sp(getContext()).edit()
          .putFloat("ts", s.floatValue())
          .putFloat("te", en.floatValue())
          .apply();
      call.resolve();
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void toneClear(PluginCall call) {
    try {
      new File(getContext().getFilesDir(), "tone.bin").delete();
      call.resolve();
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void status(PluginCall call) {
    JSObject r = new JSObject();
    r.put("ringing", AlarmService.ringing);
    r.put("label", AlarmService.rLabel);
    r.put("time", AlarmService.rTime);
    call.resolve(r);
  }

  @PluginMethod
  public void stop(PluginCall call) {
    AlarmService.stopNow();
    call.resolve();
  }

  @PluginMethod
  public void test(PluginCall call) {
    try {
      Intent s = new Intent(getContext(), AlarmService.class);
      s.putExtra("label", "منبه تجريبي");
      s.putExtra("time", "");
      ContextCompat.startForegroundService(getContext(), s);
      call.resolve();
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }
}
EOF

python3 - <<'PY'
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf8').read()
perms = ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_MEDIA_PLAYBACK', 'RECEIVE_BOOT_COMPLETED',
         'WAKE_LOCK', 'VIBRATE', 'POST_NOTIFICATIONS', 'USE_FULL_SCREEN_INTENT']
add = ''
for x in perms:
    if 'android.permission.' + x + '"' not in s:
        add += '    <uses-permission android:name="android.permission.%s"/>\n' % x
comp = '''        <receiver android:name="com.asallam.alarmenergy.AlarmReceiver" android:exported="false"/>
        <receiver android:name="com.asallam.alarmenergy.BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
        <service android:name="com.asallam.alarmenergy.AlarmService" android:exported="false" android:foregroundServiceType="mediaPlayback"/>
'''
if 'AlarmService' not in s:
    s = s.replace('</application>', comp + '    </application>')
if add:
    s = s.replace('<application', add + '    <application', 1)
open(p, 'w', encoding='utf8').write(s)
print('manifest patched')
PY

echo "native alarm code added"
