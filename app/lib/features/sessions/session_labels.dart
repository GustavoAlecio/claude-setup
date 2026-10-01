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

const kInterruptedLabel = 'interrompida — envie uma mensagem para continuar';

/// [statusLabel], except that an idle session whose process the engine restart killed asks for a new message.
String sessionStatusLabel(SessionSummary s) => s.showsInterrupted ? kInterruptedLabel : statusLabel(s.status);
