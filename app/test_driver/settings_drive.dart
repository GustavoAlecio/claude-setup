// Run from app/:
// fvm flutter drive --driver=test_driver/settings_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/settings
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
const _step = Duration(seconds: 30);

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(find.byValueKey('settings-nav'), timeout: _step);

    await driver.tap(find.byValueKey('settings-nav-stop'), timeout: _step);
    await driver.waitUntilNoTransientCallbacks(timeout: _step);
    await driver.waitFor(find.byValueKey('settings-stop-0'), timeout: _step);
    await driver.waitFor(find.byValueKey('settings-stop-2'), timeout: _step);

    await driver.tap(find.byValueKey('settings-nav-orgs'), timeout: _step);
    await driver.waitUntilNoTransientCallbacks(timeout: _step);
    await driver.tap(find.byValueKey('settings-org-row-demo'), timeout: _step);
    await driver.waitFor(find.byValueKey('settings-org-form-demo'), timeout: _step);
  } finally {
    await driver.close();
  }
}
