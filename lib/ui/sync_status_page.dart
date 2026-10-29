// 同步状态与手动操作页（`SYNC-07` 失败可见 + 重试；§10.4 手动
// 「立即同步 / 立即备份 / 从云端恢复」；`SYNC-05` 书籍文件开关与手动传输）。
//
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 不透明内容；
// 分组卡片与行复用 [SettingsGroupCard] / [SettingsTile]（与同步设置页同口径）。
//
// 结构：
//   · 「状态」：最近一轮 [SyncRunReport]——范围 / 时刻 / 汇总，失败逐条红字
//     展示（条目 + 可读原因）+ 「重试」按钮（`SYNC-07` ①②：断网可见、恢复后
//     手动重试成功）；未配置 / 未运行给引导文案；
//   · 「手动操作」：立即同步 / 立即备份 / 从云端恢复（PRD §10.4 手动行），
//     卡片脚注说明三个自动触发时机与备份间隔；
//   · 「统计数据」：同步阅读统计开关（`STAT-08` ③ 默认开，落
//     `stats_sync.json`；关闭 = 零请求，不影响其余同步项）；
//   · 「书籍文件」：上传开关（`SYNC-05` ① 默认关，落 `book_upload.json`）+
//     上传全部书籍 / 下载缺失书籍（`SYNC-05` ②③：进行中显示逐本进度与字节
//     进度，可取消）。
//
// 状态订阅（PRD §15.1 进程内单例 + 监听回调）：initState 订阅 [SyncTrigger]、
// dispose 退订、回调内 setState。
import 'package:flutter/material.dart';

import '../sync/backup.dart';
import '../sync/book_upload.dart';
import '../sync/restore.dart';
import '../sync/sync_trigger.dart';
import '../sync/webdav_client.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';

/// 页面内容左右留白（与设置页同一左边缘口径）。
const double _kPageInset = 16;

/// 同步状态与手动操作页。
class SyncStatusPage extends StatefulWidget {
  /// 创建状态页（依赖显式注入，非全局单例）。
  const SyncStatusPage({super.key, required this.trigger});

  /// 同步触发编排器（报告 / 手动动作 / 开关的唯一入口）。
  final SyncTrigger trigger;

  @override
  State<SyncStatusPage> createState() => _SyncStatusPageState();
}

class _SyncStatusPageState extends State<SyncStatusPage> {
  /// 同步 / 备份 / 恢复忙态（`null` = 空闲，否则为进行中的动作名）。
  String? _action;

  /// 书籍传输忙态。
  bool _bookBusy = false;

  /// 书籍传输取消控制器（取消当前文件后引擎停止后续书籍）。
  TransferControl? _bookControl;

  /// 当前传输进度（文件序号 / 总数 / 书名 / 已传字节 / 总字节）。
  int _bookIndex = 0;
  int _bookTotal = 0;
  String _bookName = '';
  int _bookSent = 0;
  int _bookBytes = 0;

  /// 上一次批量传输结果行（闲时展示）。
  String? _bookNote;

  @override
  void initState() {
    super.initState();
    widget.trigger.addListener(_onTrigger);
    // 开关读盘兜底（组合根已 load，这里幂等补一次防测试 / 冷路径漏加载）。
    _loadPrefsQuietly();
  }

  @override
  void dispose() {
    widget.trigger.removeListener(_onTrigger);
    _bookControl?.cancel(); // 离页即取消在途传输（不留无主任务）。
    super.dispose();
  }

  /// 异步预取（initState 不能 await；完成后补一帧）。
  void _loadPrefsQuietly() {
    Future.wait(<Future<void>>[
      widget.trigger.uploadPrefs.load(),
      widget.trigger.statsPrefs.load(),
    ]).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _onTrigger() {
    if (mounted) setState(() {});
  }

  bool get _busy => _action != null;

  // ───────────────────────────────────────────────────────────────────────────
  // 手动动作
  // ───────────────────────────────────────────────────────────────────────────

  /// 立即同步（进度 + 条目；成败落状态卡）。
  Future<void> _runSync() async {
    if (_busy) return;
    setState(() => _action = 'sync');
    final SyncRunReport report = await widget.trigger.syncNow();
    if (!mounted) return;
    setState(() => _action = null);
    if (report.wasSkipped) {
      GlassOverlays.showToast(
        context: context,
        message: report.skipReason ?? '未执行',
      );
      return;
    }
    GlassOverlays.showToast(
      context: context,
      message: report.ok
          ? '同步完成'
          : '同步完成，但有 ${report.failures.length} 项失败',
    );
  }

  /// 立即备份（不看间隔）。
  Future<void> _runBackup() async {
    if (_busy) return;
    setState(() => _action = 'backup');
    final BackupOutcome outcome = await widget.trigger.backupNow();
    if (!mounted) return;
    setState(() => _action = null);
    if (outcome.ok) {
      GlassOverlays.showToast(
        context: context,
        message: '备份完成（${outcome.fileCount} 个文件）',
      );
    } else {
      await GlassOverlays.showAlert<void>(
        context: context,
        title: '备份失败',
        message: outcome.reason ?? '未知错误',
        actions: <GlassDialogAction>[
          GlassDialogAction(
            label: '知道了',
            isPrimary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    }
  }

  /// 从云端恢复：列清单 → 确认（覆盖本机数据）→ 执行 → 结果可见。
  Future<void> _restoreFlow() async {
    if (_busy) return;
    final List<BackupEntry> list;
    try {
      list = await widget.trigger.listBackups();
    } on SyncException catch (e) {
      if (!mounted) return;
      await GlassOverlays.showAlert<void>(
        context: context,
        title: '无法列出备份',
        message: e.message,
        actions: <GlassDialogAction>[
          GlassDialogAction(
            label: '知道了',
            isPrimary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
      return;
    }
    if (!mounted) return;
    if (list.isEmpty) {
      await GlassOverlays.showAlert<void>(
        context: context,
        title: '云端暂无备份',
        message: '远端目录下没有 backup-*.zip 备份包。先在本机执行一次「立即备份」。',
        actions: <GlassDialogAction>[
          GlassDialogAction(
            label: '知道了',
            isPrimary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
      return;
    }
    final BackupEntry newest = list.first; // 清单已按新 → 旧排序。
    final bool? ok = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '从云端恢复',
      message: '将用云端最新备份覆盖本机的书架、进度、书签、设置与统计？\n\n'
          '${newest.path}\n（共 ${list.length} 份备份）',
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: '恢复',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    setState(() => _action = 'restore');
    final RestoreOutcome outcome = await widget.trigger.restoreFrom(newest.path);
    if (!mounted) return;
    setState(() => _action = null);
    await GlassOverlays.showAlert<void>(
      context: context,
      title: outcome.ok ? '恢复完成' : '恢复失败',
      message: outcome.summary,
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '知道了',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 书籍文件（`SYNC-05`）
  // ───────────────────────────────────────────────────────────────────────────

  /// 切换上传开关（`SYNC-05` ①：落 `book_upload.json`，判定在引擎入口先于
  /// 一切请求）。
  Future<void> _togglePrefs(bool value) async {
    await widget.trigger.uploadPrefs.setEnabled(value);
    if (mounted) setState(() {});
  }

  /// 切换统计同步开关（`STAT-08` ③：默认开，落 `stats_sync.json`；关闭判定
  /// 在引擎入口先于一切请求 = 零请求，且不影响其余同步项）。
  Future<void> _toggleStats(bool value) async {
    await widget.trigger.statsPrefs.setEnabled(value);
    if (mounted) setState(() {});
  }

  /// 上传全部书籍。
  Future<void> _runUpload() => _runBooks(upload: true);

  /// 下载缺失书籍。
  Future<void> _runDownload() => _runBooks(upload: false);

  Future<void> _runBooks({required bool upload}) async {
    if (_bookBusy) return;
    final TransferControl control = TransferControl();
    setState(() {
      _bookBusy = true;
      _bookControl = control;
      _bookNote = null;
      _bookIndex = 0;
      _bookTotal = 0;
      _bookName = '';
      _bookSent = 0;
      _bookBytes = 0;
    });
    final List<BookUploadOutcome> outcomes;
    if (upload) {
      outcomes = await widget.trigger.uploadBooks(
        onFile: (int index, int total, String name) {
          if (mounted) {
            setState(() {
              _bookIndex = index;
              _bookTotal = total;
              _bookName = name;
              _bookSent = 0;
              _bookBytes = 0;
            });
          }
        },
        onProgress: (int sent, int total) {
          if (mounted) {
            setState(() {
              _bookSent = sent;
              _bookBytes = total;
            });
          }
        },
        control: control,
      );
    } else {
      outcomes = await widget.trigger.downloadMissingBooks(
        onFile: (int index, int total, String name) {
          if (mounted) {
            setState(() {
              _bookIndex = index;
              _bookTotal = total;
              _bookName = name;
              _bookSent = 0;
              _bookBytes = 0;
            });
          }
        },
        onProgress: (int sent, int total) {
          if (mounted) {
            setState(() {
              _bookSent = sent;
              _bookBytes = total;
            });
          }
        },
        control: control,
      );
    }
    if (!mounted) return;
    final String note = _booksSummary(outcomes, upload ? '上传' : '下载');
    setState(() {
      _bookBusy = false;
      _bookControl = null;
      _bookNote = note;
    });
    GlassOverlays.showToast(context: context, message: note);
  }

  /// 批量结果 → 一行中文（`SYNC-07`：失败不静默，带条数）。
  String _booksSummary(List<BookUploadOutcome> outcomes, String verb) {
    if (outcomes.isEmpty) {
      return '没有可传输的书籍';
    }
    int ok = 0;
    int skipped = 0;
    int failed = 0;
    bool cancelled = false;
    for (final BookUploadOutcome outcome in outcomes) {
      switch (outcome.action) {
        case BookTransferAction.uploaded:
        case BookTransferAction.downloaded:
          ok++;
        case BookTransferAction.skipped:
          skipped++;
        case BookTransferAction.failed:
          failed++;
        case BookTransferAction.cancelled:
          cancelled = true;
      }
    }
    final String head = '已$verb $ok 本';
    final String tail = <String>[
      if (skipped > 0) '跳过 $skipped 本',
      if (failed > 0) '失败 $failed 本',
    ].join(' · ');
    final String line = tail.isEmpty ? head : '$head · $tail';
    if (cancelled) return '$line（已取消）';
    if (!widget.trigger.uploadPrefs.enabled && skipped > 0) {
      return '书籍文件同步未开启（默认关闭）';
    }
    return line;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // UI
  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('同步与备份'),
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
            _buildStatusGroup(),
            _buildManualGroup(),
            _buildStatsGroup(),
            _buildBooksGroup(),
          ],
        ),
      ),
    );
  }

  /// 「状态」组（`SYNC-07`：失败逐条可见 + 手动重试）。
  Widget _buildStatusGroup() {
    final ThemeData theme = Theme.of(context);
    final SyncTrigger trigger = widget.trigger;
    final List<Widget> children;
    if (!trigger.isConfigured) {
      children = <Widget>[
        const ListTile(
          title: Text('尚未配置 WebDAV 同步'),
          subtitle: Text('请先返回「WebDAV 同步」完成服务器配置'),
        ),
      ];
    } else if (trigger.lastReport == null) {
      children = <Widget>[
        const ListTile(
          title: Text('尚未同步'),
          subtitle: Text('启动、退出阅读页与退出应用时将自动同步'),
        ),
      ];
    } else {
      final SyncRunReport report = trigger.lastReport!;
      final List<SyncFailure> failures = report.failures;
      children = <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '上次同步（${report.scope}）· ${_fmt(report.at)}',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                report.summary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: report.ok
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
              for (final SyncFailure failure in failures)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${failure.title}：${failure.reason}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (!report.ok)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _busy ? null : _runSync,
                    child: const Text('重试'),
                  ),
                ),
            ],
          ),
        ),
      ];
    }
    return SettingsGroupCard(header: '状态', children: children);
  }

  /// 「手动操作」组（§10.4 手动行 + 自动时机脚注）。
  Widget _buildManualGroup() {
    final bool busy = _busy;
    return SettingsGroupCard(
      header: '手动操作',
      footer: '自动同步：启动时拉取进度；退出阅读页、退出应用时上报本机全部变更；'
          '全量备份距上次成功超过 ${widget.trigger.backupInterval.inDays} 天才自动触发。'
          '无系统级定时任务，只在使用应用时执行。',
      children: <Widget>[
        SettingsTile(
          icon: Icons.sync_outlined,
          accent: SettingsAccents.blue,
          title: '立即同步',
          subtitle: '拉取远端进度并上报书架索引、书签与设置',
          trailing: _action == 'sync'
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: busy ? null : _runSync,
        ),
        SettingsTile(
          icon: Icons.backup_outlined,
          accent: SettingsAccents.green,
          title: '立即备份',
          subtitle: '打包书架 / 进度 / 书签 / 设置为 zip 上传云端',
          trailing: _action == 'backup'
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: busy ? null : _runBackup,
        ),
        SettingsTile(
          icon: Icons.settings_backup_restore_outlined,
          accent: SettingsAccents.gray,
          title: '从云端恢复',
          subtitle: '用云端最新备份包覆盖本机数据（恢复前会二次确认）',
          trailing: _action == 'restore'
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: busy ? null : _restoreFlow,
        ),
      ],
    );
  }

  /// 「统计数据」组（`STAT-08` ③：默认开、可单独关闭；关闭 = 零请求）。
  Widget _buildStatsGroup() {
    final bool enabled = widget.trigger.statsPrefs.enabled;
    return SettingsGroupCard(
      header: '统计数据',
      footer: '阅读时长按会话并集合并到云端（同一条会话取较大时长），默认开启。'
          '关闭后统计不再同步到云端，进度、书签、设置与备份的同步不受影响。',
      children: <Widget>[
        SettingsTile(
          icon: Icons.timer_outlined,
          accent: SettingsAccents.orange,
          title: '同步阅读统计',
          subtitle:
              enabled ? '已开启：阅读时长记录会与云端合并' : '已关闭：阅读统计仅保留在本机',
          trailing: Switch(value: enabled, onChanged: _toggleStats),
          onTap: () => _toggleStats(!enabled),
        ),
      ],
    );
  }

  /// 「书籍文件」组（`SYNC-05`：开关默认关 + 手动传输带进度可取消）。
  Widget _buildBooksGroup() {
    final ThemeData theme = Theme.of(context);
    final bool enabled = widget.trigger.uploadPrefs.enabled;
    final String uploadSubtitle;
    if (_bookBusy) {
      final String pct = _bookBytes > 0
          ? ' · ${_bookSent * 100 ~/ _bookBytes}%'
          : '';
      uploadSubtitle = '正在$_bookName（$_bookIndex/$_bookTotal）$pct';
    } else {
      uploadSubtitle = _bookNote ?? '把本机书籍逐本上传到云端 books/ 目录';
    }
    return SettingsGroupCard(
      header: '书籍文件',
      footer: '默认关闭（不传书籍本体）。开启后可手动上传全部书籍或下载补齐'
          '本机缺失的书籍；传输中可取消，进度逐本显示。',
      children: <Widget>[
        SettingsTile(
          icon: Icons.menu_book_outlined,
          accent: SettingsAccents.purple,
          title: '上传书籍文件',
          subtitle: enabled ? '已开启：书籍文件会同步到云端' : '已关闭（默认）',
          trailing: Switch(
            value: enabled,
            onChanged: _bookBusy ? null : _togglePrefs,
          ),
          onTap: _bookBusy ? null : () => _togglePrefs(!enabled),
        ),
        SettingsTile(
          icon: Icons.cloud_upload_outlined,
          accent: SettingsAccents.blue,
          title: '上传全部书籍',
          subtitle: uploadSubtitle,
          trailing: _bookBusy
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    TextButton(
                      onPressed: () => _bookControl?.cancel(),
                      child: const Text('取消'),
                    ),
                  ],
                )
              : null,
          onTap: _bookBusy ? null : _runUpload,
        ),
        SettingsTile(
          icon: Icons.cloud_download_outlined,
          accent: SettingsAccents.green,
          title: '下载缺失书籍',
          subtitle: '从云端补齐本机缺失的书籍文件（不覆盖已有文件）',
          enabled: !_bookBusy,
          onTap: _bookBusy ? null : _runDownload,
        ),
        if (_bookNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _bookNote!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  /// `yyyy-MM-dd HH:mm`（不引 intl，口径与测试断言一致）。
  String _fmt(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
