import '../core/bloc/stream_cubit.dart';
import '../engine/engine_supervisor.dart';

class EngineCubit extends StreamCubit<EngineState> {
  EngineCubit(EngineController engine) : super(engine.watch());
}
