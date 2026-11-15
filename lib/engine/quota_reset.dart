/// When the provider says the usage quota renews, read from the CLI's own
/// message. Null when the message does not say.
///
/// Handles the forms the CLIs use:
/// - Claude: `Claude AI usage limit reached|1794683400` (epoch seconds) and
///   `You've hit your limit · resets 3pm (Europe/Rome)`;
/// - Codex: `try again in 1 day 3 hours 12 minutes` and
///   `try again at 3:05 PM` or `try again at Nov 15th, 2026 3:05 PM`.
DateTime? parseQuotaReset(String text, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final t = text.trim();
  if (t.isEmpty) return null;

  // Epoch seconds after a pipe, or in a JSON field.
  final epoch = RegExp(r'(?:\||"resets_?at"\s*:\s*)(\d{10})\b', caseSensitive: false).firstMatch(t);
  if (epoch != null) return DateTime.fromMillisecondsSinceEpoch(int.parse(epoch.group(1)!) * 1000);

  // A delay: "try again in 2 hours 13 minutes", "resets in 45 min".
  final inMatch = RegExp(
    r'(?:try again|resets?|available again)\s+in\s+((?:\d+\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[\s,and]*)+)',
    caseSensitive: false,
  ).firstMatch(t);
  if (inMatch != null) {
    var d = Duration.zero;
    for (final m in RegExp(
      r'(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b',
      caseSensitive: false,
    ).allMatches(inMatch.group(1)!)) {
      final n = int.parse(m.group(1)!);
      final unit = m.group(2)!.toLowerCase();
      d += switch (unit[0]) {
        'd' => Duration(days: n),
        'h' => Duration(hours: n),
        'm' => Duration(minutes: n),
        _ => Duration(seconds: n),
      };
    }
    if (d > Duration.zero) return at.add(d);
  }

  // A date and time: "try again at Nov 15th, 2026 3:05 PM".
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final dated = RegExp(
    r'(?:at|resets?(?:\s+at)?)\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})?,?\s*(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?',
    caseSensitive: false,
  ).firstMatch(t);
  if (dated != null) {
    final month = months.indexOf(dated.group(1)!.toLowerCase()) + 1;
    if (month > 0) {
      final hour = _hour24(int.parse(dated.group(4)!), dated.group(6));
      if (hour != null) {
        return DateTime(
          int.tryParse(dated.group(3) ?? '') ?? at.year,
          month,
          int.parse(dated.group(2)!),
          hour,
          int.tryParse(dated.group(5) ?? '') ?? 0,
        );
      }
    }
  }

  // A time of day, the next time it comes: "resets 3pm", "try again at 15:05".
  final clock = RegExp(
    r'(?:try again at|resets?(?:\s+at)?|available again at)\s+(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?',
    caseSensitive: false,
  ).firstMatch(t);
  if (clock != null && (clock.group(2) != null || clock.group(3) != null)) {
    final hour = _hour24(int.parse(clock.group(1)!), clock.group(3));
    final minute = int.tryParse(clock.group(2) ?? '') ?? 0;
    if (hour != null && minute < 60) {
      var when = DateTime(at.year, at.month, at.day, hour, minute);
      if (!when.isAfter(at)) when = when.add(const Duration(days: 1));
      return when;
    }
  }
  return null;
}

int? _hour24(int hour, String? ampm) {
  if (ampm == null) return hour < 24 ? hour : null;
  if (hour < 1 || hour > 12) return null;
  final pm = ampm.toLowerCase().startsWith('p');
  return (hour % 12) + (pm ? 12 : 0);
}
