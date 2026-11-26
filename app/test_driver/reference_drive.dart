// Run from app/:
// fvm flutter drive --driver=test_driver/reference_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/p/demo-app/artifacts
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
const _step = Duration(seconds: 30);

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(find.byValueKey('ref-item-adrs'), timeout: _step);
    await driver.waitFor(find.byValueKey('artifact-title'), timeout: _step);

    await driver.tap(find.byValueKey('ref-item-adrs'), timeout: _step);
    await driver.waitFor(find.byValueKey('adr-item-/mock/demo-app/docs/adr/0001-parser.md'), timeout: _step);

    await driver.tap(find.byValueKey('ref-item-metrics'), timeout: _step);
    await driver.waitFor(find.byValueKey('metrics-bands'), timeout: _step);
  } finally {
    await driver.close();
  }
}
