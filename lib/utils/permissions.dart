/// Permission names, as they appear in a manifest, turned into something a
/// person can read at a glance.
///
/// Only the well-known permissions get a label; everything else keeps the
/// platform's own name (`android.permission.CAMERA` -> `CAMERA`), so a diff can
/// never hide a permission just because this map has not heard of it. The
/// labels are Chinese source strings, so `AppStrings.t` translates them.
library;

/// Short name of a permission: `android.permission.CAMERA` -> `CAMERA`.
String permissionShortName(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(dot + 1);
}

const Map<String, String> _labels = <String, String>{
  'CAMERA': '相机',
  'RECORD_AUDIO': '麦克风',
  'ACCESS_FINE_LOCATION': '精确位置',
  'ACCESS_COARSE_LOCATION': '大致位置',
  'ACCESS_BACKGROUND_LOCATION': '后台位置',
  'READ_CONTACTS': '通讯录',
  'WRITE_CONTACTS': '通讯录',
  'GET_ACCOUNTS': '通讯录',
  'CALL_PHONE': '电话',
  'ANSWER_PHONE_CALLS': '电话',
  'READ_CALL_LOG': '通话记录',
  'WRITE_CALL_LOG': '通话记录',
  'READ_PHONE_STATE': '电话状态',
  'READ_PHONE_NUMBERS': '电话状态',
  'READ_SMS': '短信',
  'SEND_SMS': '短信',
  'RECEIVE_SMS': '短信',
  'RECEIVE_MMS': '短信',
  'READ_EXTERNAL_STORAGE': '照片与文件',
  'WRITE_EXTERNAL_STORAGE': '照片与文件',
  'READ_MEDIA_IMAGES': '照片与文件',
  'READ_MEDIA_VIDEO': '照片与文件',
  'READ_MEDIA_AUDIO': '照片与文件',
  'READ_MEDIA_VISUAL_USER_SELECTED': '照片与文件',
  'MANAGE_EXTERNAL_STORAGE': '照片与文件',
  'READ_CALENDAR': '日历',
  'WRITE_CALENDAR': '日历',
  'BODY_SENSORS': '身体传感器',
  'POST_NOTIFICATIONS': '通知',
  'SYSTEM_ALERT_WINDOW': '悬浮窗',
  'REQUEST_INSTALL_PACKAGES': '安装应用',
  'QUERY_ALL_PACKAGES': '读取已安装应用',
  'PACKAGE_USAGE_STATS': '使用情况访问',
  'BIND_NOTIFICATION_LISTENER_SERVICE': '通知使用权',
  'BIND_ACCESSIBILITY_SERVICE': '无障碍服务',
  'BIND_DEVICE_ADMIN': '设备管理',
  'BLUETOOTH_CONNECT': '蓝牙',
  'BLUETOOTH_SCAN': '蓝牙',
  'SCHEDULE_EXACT_ALARM': '精确闹钟',
  'WRITE_SETTINGS': '修改系统设置',
};

/// A readable label for [name]; the short platform name when unknown.
String permissionLabel(String name) =>
    _labels[permissionShortName(name)] ?? permissionShortName(name);

/// The permissions worth flagging when an update starts asking for them:
/// anything the user has to consciously allow, plus the special access that is
/// effectively a back door (accessibility, device admin, install packages…).
const Set<String> _sensitive = <String>{
  'CAMERA',
  'RECORD_AUDIO',
  'ACCESS_FINE_LOCATION',
  'ACCESS_COARSE_LOCATION',
  'ACCESS_BACKGROUND_LOCATION',
  'READ_CONTACTS',
  'WRITE_CONTACTS',
  'GET_ACCOUNTS',
  'CALL_PHONE',
  'ANSWER_PHONE_CALLS',
  'READ_CALL_LOG',
  'WRITE_CALL_LOG',
  'READ_PHONE_STATE',
  'READ_PHONE_NUMBERS',
  'READ_SMS',
  'SEND_SMS',
  'RECEIVE_SMS',
  'RECEIVE_MMS',
  'READ_EXTERNAL_STORAGE',
  'WRITE_EXTERNAL_STORAGE',
  'READ_MEDIA_IMAGES',
  'READ_MEDIA_VIDEO',
  'READ_MEDIA_AUDIO',
  'MANAGE_EXTERNAL_STORAGE',
  'READ_CALENDAR',
  'WRITE_CALENDAR',
  'BODY_SENSORS',
  'POST_NOTIFICATIONS',
  'SYSTEM_ALERT_WINDOW',
  'REQUEST_INSTALL_PACKAGES',
  'QUERY_ALL_PACKAGES',
  'PACKAGE_USAGE_STATS',
  'BIND_NOTIFICATION_LISTENER_SERVICE',
  'BIND_ACCESSIBILITY_SERVICE',
  'BIND_DEVICE_ADMIN',
};

bool isSensitivePermission(String name) =>
    _sensitive.contains(permissionShortName(name));
