import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/docs_from_environment.dart';
import 'app/inventory_from_environment.dart';
import 'app/repository_from_environment.dart';
import 'app/sessions_from_environment.dart';

void main() {
  final (:sessions, :engine, :github) = sessionsFromEnvironment();
  runApp(
    ClaudeFlowApp(
      repository: repositoryFromEnvironment(),
      sessions: sessions,
      engine: engine,
      github: github,
      inventory: inventoryFromEnvironment(),
      docs: docsFromEnvironment(),
    ),
  );
}
