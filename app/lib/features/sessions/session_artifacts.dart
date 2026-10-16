import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_repository.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';

/// Strip of the files an Antigravity session wrote to its conversation folder; refetched whenever [version] changes
/// (a turn ended), and hidden while there are none.
class SessionArtifactsStrip extends StatefulWidget {
  const SessionArtifactsStrip({super.key, required this.sessionId, required this.version});

  final String sessionId;
  final int version;

  @override
  State<SessionArtifactsStrip> createState() => _SessionArtifactsStripState();
}

class _SessionArtifactsStripState extends State<SessionArtifactsStrip> {
  List<SessionArtifact> _artifacts = const [];
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_generation == 0) unawaited(_load());
  }

  @override
  void didUpdateWidget(SessionArtifactsStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version || oldWidget.sessionId != widget.sessionId) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final artifacts = await SessionsScope.of(context).sessionArtifacts(widget.sessionId);
      if (mounted && generation == _generation) setState(() => _artifacts = artifacts);
    } on SessionsException catch (e, st) {
      log('session artifacts unavailable', name: 'SessionArtifacts', error: e, stackTrace: st);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_artifacts.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 6, right: 12), child: Muted('ARTEFATOS DA SESSÃO', size: 10)),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in _artifacts)
                  ActionChip(
                    key: ValueKey('session-artifact-${a.name}'),
                    avatar: Icon(Icons.description_outlined, size: 14, color: c.textSecondary),
                    label: Text(a.name, style: const TextStyle(fontSize: 12)),
                    tooltip: 'Abrir ${a.name}',
                    onPressed: () => showSessionArtifact(context, widget.sessionId, a.name),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Reads one session artifact in a dialog: markdown rendered, anything else as monospaced text.
Future<void> showSessionArtifact(BuildContext context, String sessionId, String name) {
  final content = SessionsScope.of(context).sessionArtifact(sessionId, name);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final c = context.colors;
      final size = MediaQuery.sizeOf(context);
      return Dialog(
        backgroundColor: c.canvas,
        child: SizedBox(
          width: 820,
          height: size.height * 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(name, style: Theme.of(context).textTheme.titleMedium)),
                    _ArtifactActions(sessionId: sessionId, name: name, content: content),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Fechar',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<String>(
                  future: content,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('${snapshot.error}', style: TextStyle(fontSize: 13, color: c.fail)),
                      );
                    }
                    final text = snapshot.data;
                    if (text == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      child: name.toLowerCase().endsWith('.md')
                          ? MarkdownView(
                              text,
                              onLink: (uri) => DocsScope.openExternal(context, uri, logName: 'SessionArtifact'),
                            )
                          : SelectableText(
                              text,
                              style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textPrimary),
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Copy, save elsewhere and show in Finder: the file lives in a hidden folder of the account's shadow HOME.
class _ArtifactActions extends StatelessWidget {
  const _ArtifactActions({required this.sessionId, required this.name, required this.content});

  final String sessionId;
  final String name;
  final Future<String> content;

  Future<void> _run(BuildContext context, String done, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
      messenger?.showSnackBar(SnackBar(content: Text(done), duration: const Duration(seconds: 2)));
    } on Exception catch (e, st) {
      log('artifact action failed', name: 'SessionArtifact', error: e, stackTrace: st);
      messenger?.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = SessionsScope.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('artifact-copy'),
          tooltip: 'Copiar conteúdo',
          iconSize: 18,
          onPressed: () => _run(context, 'conteúdo copiado', () async {
            await Clipboard.setData(ClipboardData(text: await content));
          }),
          icon: const Icon(Icons.copy),
        ),
        IconButton(
          key: const ValueKey('artifact-save'),
          tooltip: 'Salvar como…',
          iconSize: 18,
          onPressed: () async {
            final location = await getSaveLocation(suggestedName: name);
            if (location == null || !context.mounted) return;
            await _run(context, 'salvo em ${location.path}', () async {
              final bytes = Uint8List.fromList(utf8.encode(await content));
              await XFile.fromData(bytes, name: name, mimeType: 'text/markdown').saveTo(location.path);
            });
          },
          icon: const Icon(Icons.save_alt),
        ),
        IconButton(
          key: const ValueKey('artifact-reveal'),
          tooltip: 'Mostrar no Finder',
          iconSize: 18,
          onPressed: () => _run(context, 'aberto no Finder', () => sessions.revealArtifact(sessionId, name)),
          icon: const Icon(Icons.folder_open_outlined),
        ),
      ],
    );
  }
}

/// Name of the session artifact a link in an assistant turn points at (`analise.md`, `./analise.md` or a `file://`
/// URI inside the conversation folder); `null` for anything else, which keeps the default link handling.
String? artifactLinkName(Uri uri) {
  if (uri.hasScheme && uri.scheme != 'file') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty && s != '.').toList();
  if (segments.isEmpty) return null;
  if (uri.scheme == 'file' && !uri.path.contains('/brain/')) return null;
  if (uri.scheme != 'file' && segments.length != 1) return null;
  final name = segments.last;
  return name.startsWith('.') ? null : name;
}
