import '../../core/bloc/stream_cubit.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';

class SessionCubit extends StreamCubit<SessionDetail> {
  SessionCubit(SessionsRepository sessions, String id) : super(sessions.watchSession(id));
}
