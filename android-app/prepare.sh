#!/bin/bash
# Runs on GitHub during the build: adds the BRB sound, app icon, permissions and version number to the Android project.
set -e
cd "$(dirname "$0")"
RES=android/app/src/main/res
MAN=android/app/src/main/AndroidManifest.xml
mkdir -p $RES/raw $RES/drawable

# 1) the BRB message sound (Android needs a lowercase name with no dashes)
cp BRB-message-sound.wav $RES/raw/brb_message.wav

# 2) app icon from icon-512.png (plain icons, replaces the default Capacitor icon)
rm -rf $RES/mipmap-anydpi-v26
rm -f $RES/drawable-v24/ic_launcher_foreground.xml $RES/drawable/ic_launcher_background.xml
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  d=${pair%%:*}; s=${pair##*:}
  mkdir -p $RES/mipmap-$d
  convert ../icon-512.png -resize ${s}x${s} $RES/mipmap-$d/ic_launcher.png
  cp $RES/mipmap-$d/ic_launcher.png $RES/mipmap-$d/ic_launcher_round.png
  cp $RES/mipmap-$d/ic_launcher.png $RES/mipmap-$d/ic_launcher_foreground.png
done

# 3) small white chat-bubble icon for the status bar
convert -size 96x96 xc:none -fill white -draw "roundrectangle 8,10 88,68 16,16" -draw "polygon 22,64 22,90 50,64" $RES/drawable/ic_stat_brb.png

# 4) permissions (camera + microphone for calls, notifications) and Firebase defaults
python3 - <<'PY'
import re,os
p='android/app/src/main/AndroidManifest.xml'
s=open(p,encoding='utf-8').read()
perms='''<uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />
    '''
s=s.replace('<application',perms+'<application',1)
meta='''
        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="brb_messages" />
        <meta-data android:name="com.google.firebase.messaging.default_notification_icon" android:resource="@drawable/ic_stat_brb" />'''
s=re.sub(r'(<application[^>]*>)',lambda m:m.group(1)+meta,s,count=1)
open(p,'w',encoding='utf-8').write(s)
g='android/app/build.gradle'
t=open(g,encoding='utf-8').read()
t=re.sub(r'versionCode\s+\d+','versionCode '+os.environ.get('RUN_NUMBER','1'),t,count=1)
open(g,'w',encoding='utf-8').write(t)
PY
echo "prepare done"
