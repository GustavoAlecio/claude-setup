import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// `12,5` or `12.5` → 12.5; blank → `null` (no budget, or inherit); anything else → `double.nan`, an input error.
double? parseBudgetInput(String text) {
  final t = text.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v == null || v <= 0 ? double.nan : v;
}

String budgetText(double? budget) => budget == null ? '' : budget.toStringAsFixed(budget % 1 == 0 ? 0 : 2);

/// US$ amount field; [hint] says what an empty field means (no budget, or the inherited value).
class BudgetField extends StatelessWidget {
  const BudgetField({super.key, required this.controller, required this.hint, this.onChanged, this.label});

  final TextEditingController controller;
  final String hint;
  final String? label;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final invalid = parseBudgetInput(controller.text)?.isNaN ?? false;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text('US\$', style: TextStyle(fontSize: 13, color: c.textSecondary)),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        hintText: hint,
        hintStyle: TextStyle(color: c.textMuted, fontSize: 12.5),
        errorText: invalid ? 'use um valor positivo, ex.: 15 ou 7,50' : null,
      ),
    );
  }
}
