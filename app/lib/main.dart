import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/inventory_from_environment.dart';
import 'app/repository_from_environment.dart';
import 'app/sessions_from_environment.dart';

void main() {
  final (:sessions, :engine) = sessionsFromEnvironment();
  runApp(
    ClaudeFlowApp(
      repository: repositoryFromEnvironment(),
      sessions: sessions,
      engine: engine,
      inventory: inventoryFromEnvironment(),
    ),
  );
}
