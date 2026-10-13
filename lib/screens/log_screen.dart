import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../state/app_state.dart';
import '../widgets/collapsed_nav.dart';

/// Full-screen viewer for [AppLog] with module / level filtering and copy.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key, this.initialModule});

  /// Preselected module filter (e.g. opened from the notification settings).
  final LogModule? initialModule;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  LogModule? _module;
  LogLevel? _level;
  final TextEditingController _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _module = widget.initialModule;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = AppLog.instance.exportText(
      module: _module,
      minLevel: _level,
      query: _query.text,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(context.strings.t('日志已复制到剪贴板'))),
      );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final log = AppLog.instance;

    return Scaffold(
      appBar: AppBar(
        leading: CollapsedNavScope.activeOf(context)
            ? const CollapsedNavButton()
            : null,
        title: Text(
          s.t('日志'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('复制'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: s.t('清空日志'),
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              log.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final modules = log.modulesPresent();
          final entries = log.filtered(
            module: _module,
            minLevel: _level,
            query: _query.text,
          );
          return Column(
            children: [
              if (!state.loggingEnabled)
                MaterialBanner(
                  leading: const Icon(Icons.info_outline),
                  content: Text(s.t('日志未启用：打开设置里的「启用日志」后才会记录')),
                  actions: [
                    TextButton(
                      onPressed: () => state.setLoggingEnabled(true),
                      child: Text(s.t('启用')),
                    ),
                  ],
                ),
              _filters(s, modules, log.length),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          s.t('暂无日志'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final entry = entries[entries.length - 1 - i];
                          return SelectableText(
                            entry.format(),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.35,
                              color: _levelColor(context, entry.level),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Color? _levelColor(BuildContext context, LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return null;
      case LogLevel.warn:
        return Colors.orange;
      case LogLevel.error:
        return Theme.of(context).colorScheme.error;
    }
  }

  Widget _filters(AppStrings s, List<LogModule> modules, int total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              FilterChip(
                label: Text('${s.t('全部')} ($total)'),
                selected: _module == null,
                onSelected: (_) => setState(() => _module = null),
              ),
              for (final m in modules) ...[
                const SizedBox(width: 6),
                FilterChip(
                  label: Text(
                    '${s.t(m.label)} (${AppLog.instance.countFor(m)})',
                  ),
                  selected: _module == m,
                  onSelected: (on) => setState(() => _module = on ? m : null),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: s.t('搜索日志'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<LogLevel?>(
                value: _level,
                underline: const SizedBox.shrink(),
                onChanged: (v) => setState(() => _level = v),
                items: [
                  DropdownMenuItem(value: null, child: Text(s.t('全部级别'))),
                  DropdownMenuItem(
                    value: LogLevel.warn,
                    child: Text(s.t('警告及以上')),
                  ),
                  DropdownMenuItem(
                    value: LogLevel.error,
                    child: Text(s.t('仅错误')),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
