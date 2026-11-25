// Run from app/:
// fvm flutter drive --driver=test_driver/prs_drive.dart --target=test_driver/app.dart -d macos --dart-define=REPO=mock --dart-define=INITIAL_ROUTE=/p/demo-app/prs
import 'package:flutter_driver/flutter_driver.dart';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(find.byValueKey('prs-needs-you'));

    final comments = await driver.getText(find.byValueKey('pr-state-12'));
    if (comments != '1 comentário esperando você') throw StateError('pr-state-12: "$comments"');
    final merged = await driver.getText(find.byValueKey('pr-state-13'));
    if (!merged.startsWith('mergeado')) throw StateError('pr-state-13: "$merged"');
    final failed = await driver.getText(find.byValueKey('pr-state-14'));
    if (failed != 'aprovado, mas o CI falhou') throw StateError('pr-state-14: "$failed"');

    await driver.scrollIntoView(find.byValueKey('review-row-157'));
    await driver.waitFor(find.byValueKey('review-open-157'));
    await driver.scrollIntoView(find.byValueKey('review-row-9'));

    await driver.scrollIntoView(find.byValueKey('review-row-157'));
    await driver.tap(find.byValueKey('review-row-157'));
    await driver.waitFor(find.byValueKey('reviews-back'));
    await driver.tap(find.byValueKey('reviews-back'));
    await driver.waitFor(find.byValueKey('prs-mine'));
  } finally {
    await driver.close();
  }
}
