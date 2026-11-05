import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/docs_from_environment.dart';
import 'package:claude_flow/app/inventory_from_environment.dart';
import 'package:claude_flow/app/repository_from_environment.dart';
import 'package:claude_flow/app/sessions_from_environment.dart';

void main() {
  enableFlutterDriverExtension();
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
