import '../core/bloc/stream_cubit.dart';
import '../data/session_models.dart';
import '../data/sessions_repository.dart';

class SessionsCubit extends StreamCubit<List<SessionSummary>> {
  SessionsCubit(SessionsRepository sessions) : super(sessions.watchSessions());
}
