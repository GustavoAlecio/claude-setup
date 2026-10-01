import '../../data/session_models.dart';

String statusLabel(SessionStatus s) => switch (s) {
  SessionStatus.starting => 'iniciando',
  SessionStatus.running => 'rodando',
  SessionStatus.waitingPermission => 'aguardando permissão',
  SessionStatus.idle => 'aguardando resposta',
  SessionStatus.done => 'concluída',
  SessionStatus.stopped => 'interrompida',
  SessionStatus.error => 'erro',
  SessionStatus.detached => 'desanexada',
};
