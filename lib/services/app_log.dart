import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Area a log line belongs to; the log viewer filters by these.
enum LogModule {
  notifications('通知'),
  apps('应用扫描'),
  install('安装'),
  sync('同步'),
  launch('启动'),
  ui('界面'),
  other('其他');

  const LogModule(this.label);

  final String label;

  /// Parses the module name sent from the native side.
  static LogModule byName(String? name) => LogModule.values.firstWhere(
    (m) => m.name == name,
    orElse: () => LogModule.other,
  );
}

/// Severity of a log line.
enum LogLevel { info, warn, error }

/// One line in the log.
class LogEntry {
  const LogEntry(this.at, this.module, this.level, this.text);

  final DateTime at;
  final LogModule module;
  final LogLevel level;
  final String text;

  /// `12:34:56.789 [WARN] 通知 | …`
  String format() =>
      '${_clock(at)} [${level.name.toUpperCase().padRight(5)}] '
      '${module.label} | $text';

  static String _clock(DateTime t) =>
      '${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}'
      '.${_pad(t.millisecond, 3)}';

  static String _pad(int v, int width) => v.toString().padLeft(width, '0');
}

/// Opt-in, in-memory log used for troubleshooting.
///
/// Off by default and a no-op while disabled, so callers can log freely. Kept
/// in memory only (bounded to [maxEntries]); the point is to copy it out while
/// reproducing a problem, not to accumulate files.
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// Oldest entries are dropped past this.
  static const int maxEntries = 1000;

  bool _enabled = false;
  final List<LogEntry> _entries = <LogEntry>[];

  bool get enabled => _enabled;

  /// Newest last.
  List<LogEntry> get entries => UnmodifiableListView(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      _entries.add(
        LogEntry(DateTime.now(), LogModule.other, LogLevel.info, '日志已启用'),
      );
    }
    notifyListeners();
  }

  /// Records one line. Does nothing while logging is disabled.
  void log(LogModule module, String text, {LogLevel level = LogLevel.info}) {
    if (!_enabled) return;
    _entries.add(LogEntry(DateTime.now(), module, level, text));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
  }

  void warn(LogModule module, String text) =>
      log(module, text, level: LogLevel.warn);

  void error(LogModule module, String text) =>
      log(module, text, level: LogLevel.error);

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// Modules with at least one entry, in enum order.
  List<LogModule> modulesPresent() => LogModule.values
      .where((m) => _entries.any((e) => e.module == m))
      .toList(growable: false);

  int countFor(LogModule module) =>
      _entries.where((e) => e.module == module).length;

  /// Filters the log; every argument is optional.
  List<LogEntry> filtered({
    LogModule? module,
    LogLevel? minLevel,
    String query = '',
  }) {
    final needle = query.trim().toLowerCase();
    return _entries.where((e) {
      if (module != null && e.module != module) return false;
      if (minLevel != null && e.level.index < minLevel.index) return false;
      if (needle.isNotEmpty && !e.text.toLowerCase().contains(needle)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// Plain text for the clipboard, matching [filtered].
  String exportText({LogModule? module, LogLevel? minLevel, String query = ''}) {
    final lines = filtered(
      module: module,
      minLevel: minLevel,
      query: query,
    ).map((e) => e.format()).toList();
    if (lines.isEmpty) return '(空)';
    return lines.join('\n');
  }
}
