// Run from app/:
// fvm flutter drive --driver=test_driver/prs_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/p/demo-app/prs
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
const _step = Duration(seconds: 30);

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(find.byValueKey('prs-needs-you'), timeout: _step);

    final comments = await driver.getText(find.byValueKey('pr-state-12'), timeout: _step);
    if (comments != '1 comentário esperando você') throw StateError('pr-state-12: "$comments"');
    final merged = await driver.getText(find.byValueKey('pr-state-13'), timeout: _step);
    if (!merged.startsWith('mergeado')) throw StateError('pr-state-13: "$merged"');
    final failed = await driver.getText(find.byValueKey('pr-state-14'), timeout: _step);
    if (failed != 'aprovado, mas o CI falhou') throw StateError('pr-state-14: "$failed"');

    await driver.scrollIntoView(find.byValueKey('review-row-157'), timeout: _step);
    await driver.waitFor(find.byValueKey('review-open-157'), timeout: _step);
    await driver.scrollIntoView(find.byValueKey('review-row-9'), timeout: _step);

    await driver.scrollIntoView(find.byValueKey('review-row-157'), timeout: _step);
    await driver.tap(find.byValueKey('review-row-157'), timeout: _step);
    await driver.waitFor(find.byValueKey('reviews-back'), timeout: _step);
    await driver.tap(find.byValueKey('reviews-back'), timeout: _step);
    await driver.waitFor(find.byValueKey('prs-mine'), timeout: _step);
  } finally {
    await driver.close();
  }
}
