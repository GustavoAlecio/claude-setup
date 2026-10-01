import 'package:flutter/material.dart';

import '../../engine/engine_config.dart';
import '../theme/app_colors.dart';

/// "auto (classificador)" keeps the SDK mode apart from the pipeline's piloto automático.
String permissionModeLabel(PermissionMode mode) => switch (mode) {
  PermissionMode.defaultMode => 'padrão',
  PermissionMode.acceptEdits => 'aceitar edições',
  PermissionMode.auto => 'auto (classificador)',
  PermissionMode.bypassPermissions => 'bypass',
};

String permissionModeHint(PermissionMode mode) => switch (mode) {
  PermissionMode.defaultMode => 'pede confirmação para editar e rodar comandos',
  PermissionMode.acceptEdits => 'edições sem confirmação; comandos pedem',
  PermissionMode.auto => 'um classificador decide o que pede confirmação',
  PermissionMode.bypassPermissions => 'as sessões rodam sem pedir confirmação',
};

/// Red for bypass, neutral for the other modes.
Color permissionModeColor(AppColors c, PermissionMode mode) =>
    mode == PermissionMode.bypassPermissions ? c.fail : c.idle;

/// Pill with the mode that opens the list of modes; [onSelected] `null` shows it disabled.
class PermissionModeMenu extends StatelessWidget {
  const PermissionModeMenu({super.key, required this.mode, required this.onSelected, this.tooltip = 'Permissões'});

  final PermissionMode mode;
  final ValueChanged<PermissionMode>? onSelected;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = permissionModeColor(c, mode);
    final enabled = onSelected != null;
    return PopupMenuButton<PermissionMode>(
      tooltip: tooltip,
      enabled: enabled,
      color: c.elevated,
      initialValue: mode,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final m in PermissionMode.values)
          PopupMenuItem(
            value: m,
            height: 40,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(permissionModeLabel(m), style: TextStyle(fontSize: 13, color: permissionModeColor(c, m))),
                Text(permissionModeHint(m), style: TextStyle(fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              mode == PermissionMode.bypassPermissions ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 5),
            Text(
              permissionModeLabel(mode),
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: enabled ? color : c.textMuted),
          ],
        ),
      ),
    );
  }
}
