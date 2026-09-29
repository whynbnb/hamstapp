/// A single "user launched this app from Hamstapp" event.
///
/// Unlike [AppMeta.launchCount], each event keeps the exact timestamp so the
/// app can learn time-of-day habits (e.g. "opens the bike app around 08:00").
/// Events are only recorded from the point this feature existed; older aggregate
/// counts carry no time information and are therefore ignored.
class LaunchEvent {
  final String packageName;

  /// Epoch milliseconds when the app was launched.
  final int at;

  const LaunchEvent({required this.packageName, required this.at});

  factory LaunchEvent.fromMap(Map<String, dynamic> map) => LaunchEvent(
        packageName: map['p'] as String? ?? '',
        at: (map['t'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {'p': packageName, 't': at};
}
