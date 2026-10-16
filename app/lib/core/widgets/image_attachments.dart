import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/session_models.dart';
import '../platform/clipboard_image.dart';
import '../theme/app_colors.dart';

/// Same caps as the engine: up to 6 images of up to 5 MB (Claude's per-image limit).
const kMaxImages = 6;
const kMaxImageBytes = 5 * 1024 * 1024;

/// Text the engine requires when the message is only images.
const kImagesOnlyText = 'Veja a imagem anexada.';

/// Images attached to a message being written (composer, palette): ⌘V on top of the text paste, or a file picker.
mixin ImageAttachments<T extends StatefulWidget> on State<T> {
  final images = <ImageAttachment>[];
  String? imageError;
  bool _dragging = false;

  void addImage(Uint8List bytes) {
    final mediaType = ImageAttachment.mediaTypeOf(bytes);
    setState(() {
      imageError = mediaType == null
          ? 'formato não suportado: use PNG, JPEG, GIF ou WebP'
          : bytes.length > kMaxImageBytes
          ? 'imagem acima de 5 MB'
          : images.length >= kMaxImages
          ? 'no máximo $kMaxImages imagens por mensagem'
          : null;
      if (imageError == null) images.add(ImageAttachment(mediaType!, bytes));
    });
  }

  /// Hands the images over and clears them, for a send.
  List<ImageAttachment> takeImages() {
    final taken = [...images];
    setState(() {
      images.clear();
      imageError = null;
    });
    return taken;
  }

  Future<void> pickImages() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'imagens',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
          uniformTypeIdentifiers: ['public.png', 'public.jpeg', 'com.compuserve.gif', 'org.webmproject.webp'],
        ),
      ],
    );
    for (final file in files) {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      addImage(bytes);
    }
  }

  /// For a `Focus.onKeyEvent` around the text field: ⌘V still pastes text; an image on the pasteboard is attached
  /// on top of that.
  KeyEventResult onPasteKey(FocusNode _, KeyEvent event) {
    final paste =
        event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isMetaPressed;
    if (paste) {
      unawaited(
        readClipboardImage().then((bytes) {
          if (bytes != null && mounted) addImage(bytes);
        }),
      );
    }
    return KeyEventResult.ignored;
  }

  /// Files dropped on [child] are attached like picked ones; [child] gets an accent outline while something hovers.
  Widget imageDropTarget(BuildContext context, {required bool enabled, required Widget child}) {
    final c = context.colors;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        for (final file in detail.files) {
          final bytes = await file.readAsBytes();
          if (!mounted) return;
          addImage(bytes);
        }
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _dragging ? c.accent : Colors.transparent, width: 2),
        ),
        child: child,
      ),
    );
  }

  /// Thumbnails with a remove button, then the last error; nothing when both are empty.
  Widget imagesPreview(BuildContext context, {String keyPrefix = 'composer-image'}) {
    final c = context.colors;
    final error = imageError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty) ...[
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Stack(
                key: ValueKey('$keyPrefix-$i'),
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(images[i].bytes, width: 64, height: 64, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: InkWell(
                      onTap: () => setState(() => images.removeAt(i)),
                      child: Container(
                        decoration: BoxDecoration(color: c.canvas.withValues(alpha: 0.8), shape: BoxShape.circle),
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 12, color: c.textPrimary),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(error, style: TextStyle(fontSize: 12, color: c.warn)),
          ),
      ],
    );
  }
}
