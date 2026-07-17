import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/audit/pharmacy_audit_hooks.dart';
import '../../../../core/utils/kpms_feedback.dart';
import '../../../notifications/application/kpms_pharmacy_success_notifications.dart';
import '../../../notifications/domain/pharmacy_notification_models.dart';
import '../../application/medicine_csv_import_service.dart';
import '../../data/medicine_catalog_notifier.dart';

/// Entry point from Medicines → Import CSV.
Future<void> showMedicineCsvImportDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _MedicineCsvImportDialog(),
  );
}

class _MedicineCsvImportDialog extends ConsumerStatefulWidget {
  const _MedicineCsvImportDialog();

  @override
  ConsumerState<_MedicineCsvImportDialog> createState() => _MedicineCsvImportDialogState();
}

class _MedicineCsvImportDialogState extends ConsumerState<_MedicineCsvImportDialog> {
  final _pasteController = TextEditingController();
  bool _pasteMode = false;
  bool _busy = false;
  String? _fileName;
  MedicineImportParseResult? _result;
  String? _headerError;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _headerError = null;
      _result = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (file == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await file.readAsBytes();
      _fileName = file.name;
      _parseAndPreview(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      setState(() {
        _busy = false;
        _headerError = 'Could not open file: $e';
      });
    }
  }

  void _parseFromPaste() {
    _fileName = null;
    _parseAndPreview(_pasteController.text);
  }

  void _parseAndPreview(String csvText) {
    try {
      final result = MedicineCsvImportService.parse(csvText);
      setState(() {
        _busy = false;
        _result = result;
        _headerError = null;
      });
    } on MedicineImportHeaderException catch (e) {
      setState(() {
        _busy = false;
        _result = null;
        _headerError = e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _result = null;
        _headerError = 'Could not read this file as CSV: $e';
      });
    }
  }

  Future<void> _confirmImport() async {
    final result = _result;
    if (result == null || !result.hasValidRows) return;

    setState(() => _busy = true);
    ref.read(medicineCatalogProvider.notifier).addMany(result.medicines);

    unawaited(
      PharmacyAuditHooks.inventoryChange(
        action: 'medicine_bulk_imported',
        medicineId: 'csv_import_${DateTime.now().millisecondsSinceEpoch}',
        nextData: {
          'imported_count': result.medicines.length,
          'rejected_count': result.errors.length,
          'source': _fileName ?? 'pasted_csv',
        },
      ),
    );
    unawaited(
      KpmsPharmacySuccessNotifications.record(
        ref: ref,
        kind: KpmsNotificationKind.medicineAdded,
        title: 'Medicines imported',
        body: '${result.medicines.length} medicines added from CSV',
        dedupeKey: 'medicine_csv_import_${DateTime.now().millisecondsSinceEpoch}',
        payload: {'imported_count': result.medicines.length},
      ),
    );

    if (!mounted) return;
    Navigator.of(context).pop();
    kpmsSnackSuccess(context, '${result.medicines.length} medicines imported');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;

    return AlertDialog(
      title: const Text('Import medicines from CSV'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Expected columns (any order): Medicine Name, Batch Number (optional), '
                'Expiry Date (optional), Quantity, Buying Price, Selling Price, '
                'Min Stock Level (optional).',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (!_pasteMode) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pickFile,
                        icon: const Icon(Icons.upload_file_rounded),
                        label: Text(_fileName ?? 'Choose CSV file'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _pasteMode = true),
                  child: const Text('Paste CSV text instead'),
                ),
              ] else ...[
                TextField(
                  controller: _pasteController,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Medicine Name,Batch Number,Expiry Date,Quantity,Buying Price,Selling Price,Min Stock Level',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy || _pasteController.text.trim().isEmpty ? null : _parseFromPaste,
                      child: const Text('Preview'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _pasteMode = false),
                      child: const Text('Use a file instead'),
                    ),
                  ],
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_headerError != null) ...[
                const SizedBox(height: 16),
                Text(
                  _headerError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${result.medicines.length} of ${result.totalDataRows} rows ready to import',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                if (result.errors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${result.errors.length} row(s) skipped:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in result.errors.take(20))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              'Row ${e.row}: ${e.reason}',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                            ),
                          ),
                        if (result.errors.length > 20)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '+ ${result.errors.length - 20} more',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_busy || result == null || !result.hasValidRows) ? null : _confirmImport,
          child: Text(result == null ? 'Import' : 'Import ${result.medicines.length}'),
        ),
      ],
    );
  }
}
