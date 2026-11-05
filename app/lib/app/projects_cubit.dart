import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bloc/stream_cubit.dart';
import '../data/flow_repository.dart';
import '../data/models.dart';

class ProjectsCubit extends StreamCubit<List<Project>> {
  ProjectsCubit(FlowRepository repository) : super(repository.watchProjects());
}

extension ProjectLookup on BuildContext {
  /// Projeto de [name] na lista atual; sem ele, um `Project` só com o nome.
  Project projectNamed(String name) {
    final projects = read<ProjectsCubit>().state.data ?? const <Project>[];
    return projects.where((p) => p.name == name).firstOrNull ?? Project(name: name);
  }
}
