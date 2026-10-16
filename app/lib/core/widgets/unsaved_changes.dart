import 'package:flutter/material.dart';

/// Whether a form somewhere (the org editor in Configurações) holds edits Salvar has not written. Above the router, so
/// the global shortcuts that navigate away (⌘1..9, ⌘,, ⌘I) ask too, not only the page's own Voltar.
class UnsavedChangesScope extends InheritedWidget {
  const UnsavedChangesScope({super.key, required this.unsaved, required super.child});

  final ValueNotifier<bool> unsaved;

  static ValueNotifier<bool> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UnsavedChangesScope>()!.unsaved;

  @override
  bool updateShouldNotify(UnsavedChangesScope oldWidget) => unsaved != oldWidget.unsaved;
}

/// `true` when nothing is unsaved or the user chose to discard; resets the flag in that case.
Future<bool> confirmDiscard(BuildContext context, ValueNotifier<bool> unsaved) async {
  if (!unsaved.value) return true;
  final discard =
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Descartar alterações?'),
          content: const Text('A org tem alterações que ainda não foram salvas.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Continuar editando')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Descartar')),
          ],
        ),
      ) ==
      true;
  if (discard) unsaved.value = false;
  return discard;
}
