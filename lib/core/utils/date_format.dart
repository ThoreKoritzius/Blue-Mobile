import 'package:intl/intl.dart';

String formatYmd(DateTime value) => DateFormat('yyyy-MM-dd').format(value);

DateTime parseYmd(String value) {
  try {
    return DateFormat('yyyy-MM-dd').parseStrict(value);
  } catch (_) {
    return DateTime.now();
  }
}
