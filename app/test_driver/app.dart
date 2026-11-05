import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/repository_from_environment.dart';

void main() {
  enableFlutterDriverExtension();
  runApp(ClaudeFlowApp(repository: repositoryFromEnvironment()));
}
