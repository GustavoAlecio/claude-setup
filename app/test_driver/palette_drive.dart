// Run from app/:
// fvm flutter drive --driver=test_driver/palette_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/p/demo-app/flow
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
const _step = Duration(seconds: 30);

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.tap(find.byValueKey('header-palette'), timeout: _step);
    await driver.waitFor(find.byValueKey('palette-action-start'), timeout: _step);
    await driver.waitFor(find.byValueKey('palette-action-conversation'), timeout: _step);

    await driver.enterText('fix', timeout: _step);
    await driver.waitFor(find.byValueKey('palette-skill-fix'), timeout: _step);
  } finally {
    await driver.close();
  }
}
