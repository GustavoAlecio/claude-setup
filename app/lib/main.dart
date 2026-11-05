import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/repository_from_environment.dart';

void main() => runApp(ClaudeFlowApp(repository: repositoryFromEnvironment()));
