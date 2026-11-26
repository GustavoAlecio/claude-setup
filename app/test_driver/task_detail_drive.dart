// Run from app/, over a copy of test/fixtures/workflow in <dir>/workflow:
// fvm flutter drive --driver=test_driver/task_detail_drive.dart --target=test_driver/app.dart -d macos --dart-define=WORKFLOW_ROOT=<dir>/workflow --dart-define=CLAUDE_HOME=<dir> --dart-define=INITIAL_ROUTE=/p/alpha/flow
import 'package:flutter_driver/flutter_driver.dart';

const _step = Duration(seconds: 30);
const _headline = 'Task 2 de 3 · travou após 4 tentativas · escalou de haiku para sonnet';

// The driver script runs on the plain Dart VM: flutter_test needs dart:ui and package:test is not a dependency, so
// a failed step throws and the uncaught error is the non-zero exit.
Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.tap(find.byValueKey('cycle-now-action'), timeout: _step);

    final headline = await driver.getText(find.byValueKey('task-headline'), timeout: _step);
    if (headline != _headline) throw StateError('task-headline: "$headline"');
    await driver.waitFor(find.byValueKey('task-decide'), timeout: _step);
    await driver.waitFor(find.byValueKey('diagnosis-action-split_task'), timeout: _step);
    for (var n = 1; n <= 4; n++) {
      await driver.scrollIntoView(find.byValueKey('task-attempt-$n'), timeout: _step);
    }

    await driver.scrollIntoView(find.byValueKey('task-back'), timeout: _step);
    await driver.tap(find.byValueKey('task-back'), timeout: _step);
    await driver.waitForAbsent(find.byValueKey('task-headline'), timeout: _step);
    await driver.waitFor(find.byValueKey('cycle-now'), timeout: _step);
  } finally {
    await driver.close();
  }
}
