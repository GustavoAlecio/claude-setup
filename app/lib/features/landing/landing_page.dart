import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../app/projects_cubit.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  @override
  void initState() {
    super.initState();
    // BlocListener only sees changes; when '/' is revisited the list may already be loaded.
    final current = context.read<ProjectsCubit>().state;
    if (current.hasData) WidgetsBinding.instance.addPostFrameCallback((_) => _open(current));
  }

  void _open(AsyncSnapshot<List<Project>> snapshot) {
    final first = snapshot.data?.firstOrNull;
    if (mounted && first != null) context.go('/p/${first.name}/flow');
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(
      listener: (_, snapshot) => _open(snapshot),
      child: Scaffold(
        body: BlocBuilder<ProjectsCubit, AsyncSnapshot<List<Project>>>(
          builder: (_, snapshot) =>
              snapshot.connectionState == ConnectionState.waiting || snapshot.data?.isNotEmpty == true
              ? const SizedBox.shrink()
              : const Center(child: Muted('nenhum projeto em ~/.claude/workflow', size: 13)),
        ),
      ),
    );
  }
}
