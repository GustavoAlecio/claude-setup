// Run from app/:
// fvm flutter drive --driver=test_driver/metrics_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/p/demo-app/metrics
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
const _step = Duration(seconds: 30);

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(find.byValueKey('metrics-insight'), timeout: _step);
    await driver.waitFor(
      find.descendant(
        of: find.byValueKey('metrics-insight'),
        matching: find.text('Tasks grandes e de risco alto travam mais'),
      ),
      timeout: _step,
    );

    for (final id in ['completed', 'pass-tier0', 'escalations', 'cost']) {
      await driver.waitFor(find.byValueKey('metrics-card-$id'), timeout: _step);
    }
    await driver.waitFor(find.byValueKey('metrics-band-L:high'), timeout: _step);

    await driver.scrollIntoView(find.byValueKey('metrics-show-cycles'), timeout: _step);
    await driver.tap(find.byValueKey('metrics-show-cycles'), timeout: _step);
    await driver.waitFor(find.byValueKey('metrics-cycle-2026-04-20_metricas'), timeout: _step);
  } finally {
    await driver.close();
  }
}
