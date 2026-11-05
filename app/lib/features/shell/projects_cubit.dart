import '../../core/bloc/stream_cubit.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';

class ProjectsCubit extends StreamCubit<List<Project>> {
  ProjectsCubit(FlowRepository repository) : super(repository.watchProjects());
}
