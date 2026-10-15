import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../widgets/app_icon.dart';
import 'app_detail_screen.dart';

/// Who can do the sensitive things on this device.
///
/// The other direction from an app's own permission list: one capability at a
/// time — microphone, camera, location, notifications, accessibility, ... — and
/// every app that holds it. All of it comes from the system; nothing here needs
/// usage access or root.
class PermissionAuditScreen extends StatefulWidget {
  const PermissionAuditScreen({super.key});

  @override
  State<PermissionAuditScreen> createState() => _PermissionAuditScreenState();
}

class _PermissionAuditScreenState extends State<PermissionAuditScreen> {
  List<AuditCapability>? _capabilities;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final capabilities = await NativeApps.permissionAudit();
    if (!mounted) return;
    setState(() {
      _capabilities = capabilities;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final capabilities = _capabilities ?? const <AuditCapability>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('权限体检'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新检测'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : capabilities.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  s.t('没有查到任何敏感权限'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Text(
                    s.t('按能力反查谁拿到了它。点某一项可以进应用详情。'),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final c in capabilities) _section(s, c),
              ],
            ),
    );
  }

  Widget _section(AppStrings s, AuditCapability capability) {
    final scheme = Theme.of(context).colorScheme;
    final id = capability.id;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(_iconFor(id), color: scheme.primary),
        title: Text(
          s.t(capabilityName(id)),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          s.t(acknowledge(id), {'n': capability.entries.length}),
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          for (final e in capability.entries)
            ListTile(
              dense: true,
              leading: AppIcon(
                packageName: e.packageName,
                label: e.appName,
                size: 34,
                showNotificationBadge: false,
              ),
              title: Text(
                e.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                e.note.isEmpty
                    ? e.packageName
                    : s.t('{pkg} · {note}', {
                        'pkg': e.packageName,
                        'note': e.note,
                      }),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: e.isSystem
                  ? Text(
                      s.t('系统'),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppDetailScreen(packageName: e.packageName),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Chinese source name of a capability id (see the native audit).
String capabilityName(String id) => switch (id) {
  'microphone' => '麦克风',
  'camera' => '相机',
  'location' => '定位',
  'backgroundLocation' => '后台定位',
  'contacts' => '通讯录',
  'phone' => '电话与通话记录',
  'sms' => '短信',
  'media' => '照片、音乐与文件',
  'calendar' => '日历',
  'sensors' => '身体传感器',
  'notifications' => '发送通知',
  'overlay' => '悬浮窗',
  'installPackages' => '安装未知应用',
  'writeSettings' => '修改系统设置',
  'usageAccess' => '使用情况访问',
  'notificationAccess' => '通知使用权',
  'accessibility' => '无障碍服务',
  'batteryUnrestricted' => '电池优化白名单',
  _ => id,
};

/// One line explaining what holding that capability means.
String acknowledge(String id) => switch (id) {
  'microphone' => '{n} 个应用可以随时录音',
  'camera' => '{n} 个应用可以拍照或录像',
  'location' => '{n} 个应用可以读取位置',
  'backgroundLocation' => '{n} 个应用可以在后台持续定位',
  'contacts' => '{n} 个应用可以读取或修改联系人',
  'phone' => '{n} 个应用可以打电话、读通话记录',
  'sms' => '{n} 个应用可以收发或读取短信',
  'media' => '{n} 个应用可以读取照片、音乐或文件',
  'calendar' => '{n} 个应用可以读写日历',
  'sensors' => '{n} 个应用可以读取身体传感器',
  'notifications' => '{n} 个应用可以弹出通知',
  'overlay' => '{n} 个应用可以在其它应用上悬浮显示',
  'installPackages' => '{n} 个应用可以安装其它应用',
  'writeSettings' => '{n} 个应用可以修改系统设置',
  'usageAccess' => '{n} 个应用可以查看你的使用情况',
  'notificationAccess' => '{n} 个应用可以读取所有通知',
  'accessibility' => '{n} 个应用可以读取屏幕内容并代替你操作',
  'batteryUnrestricted' => '{n} 个应用不受电池优化限制，可以长期在后台运行',
  _ => '{n} 个应用',
};

IconData _iconFor(String id) => switch (id) {
  'microphone' => Icons.mic_none,
  'camera' => Icons.photo_camera_outlined,
  'location' || 'backgroundLocation' => Icons.place_outlined,
  'contacts' => Icons.contacts_outlined,
  'phone' => Icons.phone_outlined,
  'sms' => Icons.sms_outlined,
  'media' => Icons.photo_library_outlined,
  'calendar' => Icons.event_outlined,
  'sensors' => Icons.favorite_border,
  'notifications' => Icons.notifications_outlined,
  'overlay' => Icons.layers_outlined,
  'installPackages' => Icons.download_for_offline_outlined,
  'writeSettings' => Icons.tune,
  'usageAccess' => Icons.insights_outlined,
  'notificationAccess' => Icons.mark_email_unread_outlined,
  'accessibility' => Icons.accessibility_new,
  'batteryUnrestricted' => Icons.battery_saver_outlined,
  _ => Icons.shield_outlined,
};
