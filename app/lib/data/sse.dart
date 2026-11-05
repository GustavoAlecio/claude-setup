class SseFrame {
  const SseFrame(this.event, this.data);

  final String event;
  final String data;

  @override
  String toString() => 'SseFrame($event, $data)';
}

/// Splits [buffer] into complete frames; the trailing incomplete block comes back as `rest`
/// to be prepended to the next chunk. Comment-only blocks (keepalive) produce no frame.
(List<SseFrame>, String) parseSse(String buffer) {
  final normalized = buffer.replaceAll('\r\n', '\n');
  final blocks = normalized.split('\n\n');
  final rest = blocks.removeLast();
  final frames = <SseFrame>[];
  for (final block in blocks) {
    String? event;
    final data = <String>[];
    for (final line in block.split('\n')) {
      if (line.isEmpty || line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          data.add(value);
      }
    }
    if (event == null && data.isEmpty) continue;
    frames.add(SseFrame(event ?? 'message', data.join('\n')));
  }
  return (frames, rest);
}
