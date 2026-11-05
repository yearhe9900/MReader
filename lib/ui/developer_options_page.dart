// 开发者选项子页：PDF 解析内核的实验开关（「我的」页入口，不进用户主流程）。
//
// 形制同 AI 设置页：玻璃顶栏（导航层）+ [OpaqueContentSurface] 不透明内容；
// 开关统一 [MiSwitch]（禁裸 Material Switch / SwitchListTile）。
import 'package:flutter/material.dart';

import '../settings/developer_options.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart' show MiSwitch;
import 'settings_kit.dart';

const double _kPageInset = 16;

/// 开发者选项页（无持久化：开关仅本次运行生效）。
class DeveloperOptionsPage extends StatefulWidget {
  const DeveloperOptionsPage({super.key});

  @override
  State<DeveloperOptionsPage> createState() => _DeveloperOptionsPageState();
}

class _DeveloperOptionsPageState extends State<DeveloperOptionsPage> {
  void _toggle(bool value) {
    setState(() => DeveloperOptions.pdfUseRustKernel = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool useRust = DeveloperOptions.pdfUseRustKernel;
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('开发者选项'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: OpaqueContentSurface(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            _kPageInset,
            16,
            _kPageInset,
            kShellBottomInset,
          ),
          children: <Widget>[
            SettingsGroupCard(
              header: '解析内核',
              footer: '仅本次运行生效；切换后重新打开 PDF 才会用新内核。'
                  '两种内核的进度坐标不同，切换后该书的阅读进度会重新定位。',
              children: <Widget>[
                SettingsTile(
                  icon: Icons.science_outlined,
                  accent: SettingsAccents.orange,
                  title: 'PDF 使用 Rust 内核',
                  subtitle: useRust
                      ? '当前：文字版重排（可复制 / 可调字号，扫描件可能无内容）'
                      : '当前：原版式图片页（保留版式与双指缩放）',
                  trailing: MiSwitch(value: useRust, onChanged: _toggle),
                  onTap: () => _toggle(!useRust),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
