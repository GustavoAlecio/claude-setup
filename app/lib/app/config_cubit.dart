import '../core/bloc/stream_cubit.dart';
import '../data/flow_repository.dart';
import '../engine/engine_config.dart';

class ConfigCubit extends StreamCubit<DashboardConfig> {
  ConfigCubit(FlowRepository repository) : super(repository.watchConfig());
}
