import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// hide: deferred imports must hide all extensions; these two String helpers are
// internal to the excel package and unused here.
import 'package:excel/excel.dart' deferred as xlsx hide BoolParsing, StringExt;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' deferred as pdf;
import 'package:pdf/widgets.dart' deferred as pw;
import 'package:share_plus/share_plus.dart';

import '../../../core/branding/invoice_logo_bytes.dart';
import '../../../core/constants/app_constants.dart';
import '../domain/ledger_tx_view.dart';

String _csvCell(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

Future<void> _shareBytes({
  required String fileName,
  required List<int> bytes,
  required String mimeType,
}) async {
  final data = Uint8List.fromList(bytes);
  if (kIsWeb) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(data, name: fileName, mimeType: mimeType)],
        subject: '${AppConstants.appName} — transactions',
        fileNameOverrides: [fileName],
      ),
    );
    return;
  }
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/$fileName';
  await File(path).writeAsBytes(data);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path, mimeType: mimeType, name: fileName)],
      subject: '${AppConstants.appName} — transactions',
    ),
  );
}

/// Exports transaction table — PDF is print-only content (no app chrome).
abstract final class TransactionExportService {
  static Future<void> exportCsv(List<LedgerTxView> rows, {required String pharmacyName}) async {
    final buf = StringBuffer();
    buf.writeln(
      [_csvCell('When'), _csvCell('Type'), _csvCell('Reference'), _csvCell('Party'), _csvCell('Amount'), _csvCell('Payment'), _csvCell('Status'), _csvCell('Staff')]
          .join(','),
    );
    for (final r in rows) {
      buf.writeln(
        [
          _csvCell(r.whenLabel),
          _csvCell(r.kindLabel),
          _csvCell(r.reference),
          _csvCell(r.party),
          _csvCell(r.amount.toStringAsFixed(2)),
          _csvCell(r.paymentMethod),
          _csvCell(r.status),
          _csvCell(r.staffLabel),
        ].join(','),
      );
    }
    final bytes = utf8.encode(buf.toString());
    await _shareBytes(
      fileName: 'transactions_${DateTime.now().millisecondsSinceEpoch}.csv',
      bytes: bytes,
      mimeType: 'text/csv',
    );
  }

  static Future<void> exportExcel(List<LedgerTxView> rows, {required String pharmacyName}) async {
    await xlsx.loadLibrary();
    final excel = xlsx.Excel.createExcel();
    final sheetName = excel.getDefaultSheet() ?? excel.tables.keys.first;
    final sheet = excel[sheetName];
    sheet.appendRow([xlsx.TextCellValue(pharmacyName)]);
    sheet.appendRow([xlsx.TextCellValue('Transactions')]);
    sheet.appendRow([]);
    sheet.appendRow([
      xlsx.TextCellValue('When'),
      xlsx.TextCellValue('Type'),
      xlsx.TextCellValue('Reference'),
      xlsx.TextCellValue('Party'),
      xlsx.TextCellValue('Amount'),
      xlsx.TextCellValue('Payment'),
      xlsx.TextCellValue('Status'),
      xlsx.TextCellValue('Staff'),
    ]);
    for (final r in rows) {
      sheet.appendRow([
        xlsx.TextCellValue(r.whenLabel),
        xlsx.TextCellValue(r.kindLabel),
        xlsx.TextCellValue(r.reference),
        xlsx.TextCellValue(r.party),
        xlsx.TextCellValue(r.amount.toStringAsFixed(2)),
        xlsx.TextCellValue(r.paymentMethod),
        xlsx.TextCellValue(r.status),
        xlsx.TextCellValue(r.staffLabel),
      ]);
    }
    final bytes = excel.encode();
    if (bytes == null) throw StateError('Excel encode failed');
    await _shareBytes(
      fileName: 'transactions_${DateTime.now().millisecondsSinceEpoch}.xlsx',
      bytes: bytes,
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  static Future<void> exportPdf(List<LedgerTxView> rows, {required String pharmacyName, String? logoUrl}) async {
    await pdf.loadLibrary();
    await pw.loadLibrary();
    final doc = pw.Document();
    dynamic logoImg; // deferred pw.MemoryImage — dynamic avoids a deferred type annotation.
    final logoBytes = await fetchInvoiceLogoBytes(logoUrl);
    if (logoBytes != null && logoBytes.isNotEmpty) {
      try {
        logoImg = pw.MemoryImage(logoBytes);
      } catch (_) {}
    }
    doc.addPage(
      pw.MultiPage(
        margin: pw.EdgeInsets.all(36),
        build: (ctx) => [
          if (logoImg != null) pw.Center(child: pw.Image(logoImg, width: 72, fit: pw.BoxFit.contain)),
          if (logoImg != null) pw.SizedBox(height: 8),
          pw.Text(pharmacyName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('Transaction register', style: pw.TextStyle(fontSize: 11, color: pdf.PdfColors.grey700)),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: const ['When', 'Type', 'Reference', 'Party', 'Amount', 'Payment', 'Status', 'Staff'],
            data: [
              for (final r in rows)
                [
                  r.whenLabel,
                  r.kindLabel,
                  r.reference,
                  r.party,
                  r.amount.toStringAsFixed(2),
                  r.paymentMethod,
                  r.status,
                  r.staffLabel,
                ],
            ],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: pw.TextStyle(fontSize: 8),
            headerDecoration: pw.BoxDecoration(color: pdf.PdfColors.grey300),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          ),
          pw.SizedBox(height: 20),
          pw.Text('Generated ${DateTime.now().toIso8601String()}', style: pw.TextStyle(fontSize: 8, color: pdf.PdfColors.grey600)),
        ],
      ),
    );
    final bytes = await doc.save();
    await _shareBytes(
      fileName: 'transactions_${DateTime.now().millisecondsSinceEpoch}.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
    );
  }

  /// Single-row PDF for sharing one transaction from the register.
  static Future<void> exportSingleRowPdf(LedgerTxView row, {required String pharmacyName, String? logoUrl}) async {
    await pdf.loadLibrary();
    await pw.loadLibrary();
    final doc = pw.Document();
    dynamic logoImg; // deferred pw.MemoryImage — dynamic avoids a deferred type annotation.
    final logoBytes = await fetchInvoiceLogoBytes(logoUrl);
    if (logoBytes != null && logoBytes.isNotEmpty) {
      try {
        logoImg = pw.MemoryImage(logoBytes);
      } catch (_) {}
    }
    // Local function (inferred return type) — a static method can't declare a
    // deferred pw.TableRow return type.
    kv(String k, String v) => pw.TableRow(
          children: [
            pw.Padding(
              padding: pw.EdgeInsets.all(6),
              child: pw.Text(k, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Padding(
              padding: pw.EdgeInsets.all(6),
              child: pw.Text(v, style: pw.TextStyle(fontSize: 9)),
            ),
          ],
        );
    doc.addPage(
      pw.Page(
        margin: pw.EdgeInsets.all(40),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (logoImg != null) pw.Center(child: pw.Image(logoImg, width: 64, fit: pw.BoxFit.contain)),
            if (logoImg != null) pw.SizedBox(height: 8),
            pw.Text(pharmacyName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Transaction', style: pw.TextStyle(fontSize: 11, color: pdf.PdfColors.grey700)),
            pw.SizedBox(height: 18),
            pw.Table(
              border: pw.TableBorder.all(color: pdf.PdfColors.grey400, width: 0.4),
              columnWidths: {
                0: pw.FixedColumnWidth(88),
                1: pw.FlexColumnWidth(),
              },
              children: [
                kv('When', row.whenLabel),
                kv('Type', row.kindLabel),
                kv('Reference', row.reference),
                kv('Party', row.party),
                kv('Amount', row.amount.toStringAsFixed(2)),
                kv('Payment', row.paymentMethod),
                kv('Status', row.status),
                kv('Staff', row.staffLabel),
              ],
            ),
            pw.SizedBox(height: 22),
            pw.Text(
              'Generated ${DateTime.now().toIso8601String()}',
              style: pw.TextStyle(fontSize: 8, color: pdf.PdfColors.grey600),
            ),
          ],
        ),
      ),
    );
    final bytes = await doc.save();
    await _shareBytes(
      fileName: 'transaction_${row.reference}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
    );
  }
}
