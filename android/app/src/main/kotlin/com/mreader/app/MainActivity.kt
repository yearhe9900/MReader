package com.mreader.app

import com.ryanheise.audioservice.AudioServiceActivity

// `TTS-03`（M3-T07）：audio_service 要求 Activity 继承其基类以共享
// FlutterEngine（通知栏冷启 / 媒体键路由用）；清单里 .MainActivity 不变。
class MainActivity : AudioServiceActivity()
