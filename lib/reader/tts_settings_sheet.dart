// `TTS-04` / `TTS-05`：朗读设置面板（语速 / 音色 / 定时停止）。
//
// 与 [ReadingAppearanceSheet] 同款形制：面板只做 UI——本地副本 + `_emit`
// 整份回传，落盘与引擎应用都在调用方（`ReaderPage._onTtsSettingsChanged`）。
//
// 验收映射：
//   · `TTS-04` ① 语速滑块拖动中即回传（调用方立即应用引擎）；② 音色 chip
//     切换回传 voiceName/locale；「跟随系统语速」开时滑块禁用；
//     音色列表为空（Linux 等无引擎平台）→ 音色区整体隐藏（诚实降级）；
//   · `TTS-05` 定时 chips 关闭 / 10~180 分钟（10 步进），设定持久化在 store。
import 'package:flutter/material.dart';

import '../tts/tts_engine.dart';
import '../tts/tts_settings.dart';

/// 朗读设置面板（语速 / 音色 / 定时停止）。
class TtsSettingsSheet extends StatefulWidget {
  const TtsSettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
    this.voices,
  });

  /// 当前朗读设置（打开面板时的快照）。
  final TtsSettings settings;

  /// 每次调整**立即**回传整份新设置（实时生效；持久化由调用方负责）。
  final ValueChanged<TtsSettings> onChanged;

  /// 系统可用音色；`null` / 空 = 平台不支持或查询失败 → 音色区整体隐藏。
  final List<TtsVoice>? voices;

  @override
  State<TtsSettingsSheet> createState() => _TtsSettingsSheetState();
}

class _TtsSettingsSheetState extends State<TtsSettingsSheet> {
  late TtsSettings _settings = widget.settings;

  /// 更新设置并立即回传（实时生效）。
  void _emit(TtsSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  /// 换音色（[TtsSettings.copyWith] 无法显式置空可空字段 → 直接构造）。
  void _emitVoice(TtsVoice? voice) {
    _emit(TtsSettings(
      rate: _settings.rate,
      followSystemRate: _settings.followSystemRate,
      voiceName: voice?.name,
      voiceLocale: voice?.locale,
      sleepMinutes: _settings.sleepMinutes,
    ));
  }

  /// 语速展示倍率（flutter_tts 0.5 = 系统正常速 = 1.0x）。
  String _rateLabel(double rate) => '${(rate * 2).toStringAsFixed(1)}x';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<TtsVoice>? voices = widget.voices;
    final bool hasVoices = voices != null && voices.isNotEmpty;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('朗读设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Text('语速', style: theme.textTheme.labelLarge),
              Row(
                children: <Widget>[
                  const Icon(Icons.slow_motion_video, size: 20),
                  Expanded(
                    child: Slider(
                      key: const Key('tts-rate-slider'),
                      value: TtsSettings.clampRate(_settings.rate),
                      min: TtsSettings.minRate,
                      max: TtsSettings.maxRate,
                      divisions: 30,
                      label: _rateLabel(_settings.rate),
                      // 跟随系统语速时禁用（`TTS-04` 开关语义）。
                      onChanged: _settings.followSystemRate
                          ? null
                          : (double value) =>
                              _emit(_settings.copyWith(rate: value)),
                    ),
                  ),
                  const Icon(Icons.speed, size: 20),
                ],
              ),
              SwitchListTile(
                key: const Key('tts-follow-rate'),
                contentPadding: EdgeInsets.zero,
                title: const Text('跟随系统语速'),
                value: _settings.followSystemRate,
                onChanged: (bool value) =>
                    _emit(_settings.copyWith(followSystemRate: value)),
              ),
              // 音色（`TTS-04`②）：列表为空 = 平台无引擎查询面 → 不摆空区块。
              if (hasVoices) ...<Widget>[
                const SizedBox(height: 8),
                Text('音色', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    ChoiceChip(
                      key: const Key('tts-voice-default'),
                      label: const Text('系统默认'),
                      selected: _settings.voiceName == null,
                      onSelected: (_) => _emitVoice(null),
                    ),
                    for (final TtsVoice voice in voices)
                      ChoiceChip(
                        label: Text(voice.name.isEmpty
                            ? voice.locale
                            : voice.name),
                        selected: _settings.voiceName == voice.name,
                        onSelected: (_) => _emitVoice(voice),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('定时停止', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    key: const Key('tts-sleep-off'),
                    label: const Text('关闭'),
                    selected: _settings.sleepMinutes == 0,
                    onSelected: (_) =>
                        _emit(_settings.copyWith(sleepMinutes: 0)),
                  ),
                  for (int m = TtsSettings.minSleepMinutes;
                      m <= TtsSettings.maxSleepMinutes;
                      m += TtsSettings.sleepStepMinutes)
                    ChoiceChip(
                      key: Key('tts-sleep-$m'),
                      label: Text('$m 分钟'),
                      selected: _settings.sleepMinutes == m,
                      onSelected: (_) =>
                          _emit(_settings.copyWith(sleepMinutes: m)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
