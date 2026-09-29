import 'dart:math' as math;

import '../models/launch_event.dart';

/// A time-of-day based suggestion produced by [Recommender].
class Recommendation {
  final String packageName;

  /// Habit strength right now. Higher means the app is used more consistently
  /// around this time of day.
  final double score;

  /// Representative minute of day (0..1439) the app is usually launched at.
  final int typicalMinute;

  /// How many distinct days contributed to this suggestion.
  final int sampleDays;

  const Recommendation({
    required this.packageName,
    required this.score,
    required this.typicalMinute,
    required this.sampleDays,
  });
}

/// Learns "what do I usually open around this time" from timestamped launches.
///
/// Strategy (deliberately not fixed time buckets):
///
/// * Each launch contributes a smooth kernel over the time of day, centered on
///   the moment it happened. A launch at 07:55 and one at 08:05 both weigh on a
///   query at 08:00, so a habit split across a bucket boundary is not halved.
/// * Recent launches weigh more than old ones (exponential half-life), so
///   routines can drift.
/// * Weekday and weekend launches are weighted differently, because a commute
///   habit is usually a workday thing.
/// * An app only qualifies when "now" is a genuine peak for it
///   ([Recommendation] prominence) and it was seen on enough distinct days, so
///   one-off launches are not recommended.
class Recommender {
  const Recommender._();

  static const int minutesPerDay = 1440;

  /// Width of the time-of-day kernel, in minutes.
  static const double sigmaMinutes = 45;

  /// Launches older than this many days lose half their weight.
  static const double halfLifeDays = 30;

  /// Ignore launches further than this many sigmas from the query time.
  static const double maxSigmas = 3;

  /// Minimum number of recorded launches before an app can be suggested.
  static const int minEvents = 2;

  /// Minimum distinct days with a launch near the query time. One is enough so
  /// a routine can show up the same day it is first observed.
  static const int minDays = 1;

  /// "Now" must be at least this much stronger than the app's daily average.
  static const double minProminence = 1.3;

  /// How strongly a launch whose weekday/weekend type differs from "now" is
  /// down-weighted.
  static const double otherDayTypeWeight = 0.35;

  /// Suggests up to [limit] apps for the moment [nowMillis].
  static List<Recommendation> recommend(
    List<LaunchEvent> events, {
    required int nowMillis,
    int limit = 8,
    double sigma = sigmaMinutes,
    double halfLife = halfLifeDays,
    int minEvents = minEvents,
    int minDays = minDays,
    double minProminence = minProminence,
  }) {
    final now = DateTime.fromMillisecondsSinceEpoch(nowMillis);
    final nowTod = now.hour * 60 + now.minute;
    final nowIsWorkday = _isWorkday(now);

    final grouped = <String, List<_Sample>>{};
    for (final e in events) {
      if (e.at <= 0 || e.at > nowMillis) continue;
      final ageDays =
          (nowMillis - e.at) / Duration.millisecondsPerDay;
      final at = DateTime.fromMillisecondsSinceEpoch(e.at);
      grouped.putIfAbsent(e.packageName, () => <_Sample>[]).add(
            _Sample(
              tod: at.hour * 60 + at.minute,
              decay: math.pow(0.5, ageDays / halfLife).toDouble(),
              typeWeight: _isWorkday(at) == nowIsWorkday
                  ? 1.0
                  : otherDayTypeWeight,
              dayKey: '${at.year}-${at.month}-${at.day}',
            ),
          );
    }

    final out = <Recommendation>[];
    for (final entry in grouped.entries) {
      final samples = entry.value;
      if (samples.length < minEvents) continue;

      final scoreNow = _scoreAt(nowTod, samples, sigma);

      // How "special" is now relative to the app's whole day?
      var daySum = 0.0;
      const samplesPerDay = 48;
      for (var i = 0; i < samplesPerDay; i++) {
        daySum += _scoreAt(
          i * (minutesPerDay ~/ samplesPerDay),
          samples,
          sigma,
        );
      }
      final dayMean = daySum / samplesPerDay;
      if (dayMean <= 0) continue;
      if (scoreNow / dayMean < minProminence) continue;

      // Distinct days that actually contributed near "now".
      final days = <String>{};
      var sinSum = 0.0;
      var cosSum = 0.0;
      var weightSum = 0.0;
      for (final s in samples) {
        final d = _circularDistance(nowTod, s.tod);
        final k = math.exp(-0.5 * (d / sigma) * (d / sigma));
        if (k <= 0.01) continue;
        days.add(s.dayKey);
        final w = s.decay * s.typeWeight * k;
        final rad = 2 * math.pi * s.tod / minutesPerDay;
        sinSum += w * math.sin(rad);
        cosSum += w * math.cos(rad);
        weightSum += w;
      }
      if (days.length < minDays) continue;

      final typical = weightSum > 0
          ? _circularMeanMinute(sinSum, cosSum)
          : nowTod;
      out.add(
        Recommendation(
          packageName: entry.key,
          score: scoreNow,
          typicalMinute: typical,
          sampleDays: days.length,
        ),
      );
    }

    out.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.packageName.compareTo(b.packageName);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  static double _scoreAt(int minute, List<_Sample> samples, double sigma) {
    var sum = 0.0;
    for (final s in samples) {
      final d = _circularDistance(minute, s.tod);
      if (d > sigma * maxSigmas) continue;
      sum += s.decay *
          s.typeWeight *
          math.exp(-0.5 * (d / sigma) * (d / sigma));
    }
    return sum;
  }

  static bool _isWorkday(DateTime d) => d.weekday <= DateTime.friday;

  /// Shortest distance between two minutes of day, handling the midnight wrap.
  static double _circularDistance(int a, int b) {
    final raw = (a - b) % minutesPerDay;
    final d = raw < 0 ? raw + minutesPerDay : raw;
    return d <= minutesPerDay / 2 ? d.toDouble() : (minutesPerDay - d).toDouble();
  }

  static int _circularMeanMinute(double sinSum, double cosSum) {
    if (sinSum == 0 && cosSum == 0) return 0;
    var deg = math.atan2(sinSum, cosSum) * 180 / math.pi;
    if (deg < 0) deg += 360;
    return ((deg / 360) * minutesPerDay).round() % minutesPerDay;
  }
}

class _Sample {
  final int tod;
  final double decay;
  final double typeWeight;
  final String dayKey;

  const _Sample({
    required this.tod,
    required this.decay,
    required this.typeWeight,
    required this.dayKey,
  });
}
