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
import '../../../core/reports/kpms_report_log.dart';
import 'report_models.dart';

String _csvCell(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _sanitizeTenantForFile(String? tenantId) {
  if (tenantId == null || tenantId.trim().isEmpty) return '';
  final t = tenantId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
  if (t.length > 28) return t.substring(0, 28);
  return t;
}

String _exportStem(ReportDataset d, String? tenantId) {
  final tid = _sanitizeTenantForFile(tenantId);
  final ts = DateTime.now().millisecondsSinceEpoch;
  if (tid.isEmpty) return 'kpms_${d.reportId.slug}_$ts';
  return 'kpms_${d.reportId.slug}_${tid}_$ts';
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
        subject: '${AppConstants.appName} — export',
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
      subject: '${AppConstants.appName} — export',
    ),
  );
}

/// PDF / Excel / CSV with branding and filter context.
abstract final class ReportExportService {
  static Future<void> exportPdf(
    ReportDataset d, {
    String? pharmacyName,
    String? logoUrl,
    String? tenantId,
  }) async {
    // Deferred: pull the pdf code split on first export instead of at web startup.
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
    final pharmacy = pharmacyName?.trim();

    doc.addPage(
      pw.MultiPage(
        pageFormat: pdf.PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(32),
        build: (ctx) => [
          pw.Header(
            level: 0,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (logoImg != null) ...[
                  pw.Center(child: pw.Image(logoImg, width: 72, fit: pw.BoxFit.contain)),
                  pw.SizedBox(height: 6),
                ],
                if (pharmacy != null && pharmacy.isNotEmpty) ...[
                  pw.Text(pharmacy, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 2),
                ],
                pw.Text(AppConstants.appFullName, style: pw.TextStyle(fontSize: 9, color: pdf.PdfColors.grey700)),
                pw.SizedBox(height: 4),
                pw.Text(d.reportId.title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
                pw.Text('Period: ${d.rangeLabel}', style: pw.TextStyle(fontSize: 10)),
                pw.Text('Filters: ${d.filterFootnote}', style: pw.TextStyle(fontSize: 9)),
              ],
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final m in d.summaries)
                pw.Container(
                  width: 160,
                  padding: pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: pdf.PdfColors.grey300),
                    borderRadius: pw.BorderRadius.all(pw.Radius.circular(8)),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(m.label, style: pw.TextStyle(fontSize: 8, color: pdf.PdfColors.grey700)),
                      pw.Text(m.value, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                      if (m.deltaLabel != null)
                        pw.Text(m.deltaLabel!, style: pw.TextStyle(fontSize: 7, color: pdf.PdfColors.grey600)),
                    ],
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 20),
          pw.Text('Detail', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: d.tableColumns,
            data: d.tableRows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: pw.TextStyle(fontSize: 8),
            headerDecoration: pw.BoxDecoration(color: pdf.PdfColors.grey200),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            border: null,
          ),
          for (final sec in d.extraSections) ...[
            pw.SizedBox(height: 18),
            pw.Text(sec.title, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            if (sec.rows.isEmpty)
              pw.Text('No rows', style: pw.TextStyle(fontSize: 8, color: pdf.PdfColors.grey600))
            else
              pw.TableHelper.fromTextArray(
                headers: sec.columns,
                data: sec.rows,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                cellStyle: pw.TextStyle(fontSize: 8),
                headerDecoration: pw.BoxDecoration(color: pdf.PdfColors.grey200),
                cellAlignment: pw.Alignment.centerLeft,
                cellPadding: pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                border: null,
              ),
          ],
          pw.SizedBox(height: 24),
          pw.Center(
            child: pw.Text(
              '${AppConstants.appName} · Confidential pharmacy analytics',
              style: pw.TextStyle(fontSize: 8, color: pdf.PdfColors.grey500),
            ),
          ),
        ],
      ),
    );

    final bytes = await doc.save();
    final stem = _exportStem(d, tenantId);
    await _shareBytes(
      fileName: '$stem.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
    );
  }

  static Future<void> exportExcel(ReportDataset d, {String? tenantId}) async {
    await xlsx.loadLibrary();
    final excel = xlsx.Excel.createExcel();
    final sheetName = excel.getDefaultSheet() ?? excel.tables.keys.first;
    final sheet = excel[sheetName];

    sheet.appendRow([xlsx.TextCellValue(AppConstants.appFullName)]);
    sheet.appendRow([xlsx.TextCellValue(d.reportId.title)]);
    sheet.appendRow([xlsx.TextCellValue('Period: ${d.rangeLabel}')]);
    sheet.appendRow([xlsx.TextCellValue('Filters: ${d.filterFootnote}')]);
    sheet.appendRow([]);

    for (final m in d.summaries) {
      sheet.appendRow([
        xlsx.TextCellValue(m.label),
        xlsx.TextCellValue(m.value),
        if (m.deltaLabel != null) xlsx.TextCellValue(m.deltaLabel!),
      ]);
    }
    sheet.appendRow([]);

    sheet.appendRow([for (final c in d.tableColumns) xlsx.TextCellValue(c)]);
    for (final row in d.tableRows) {
      sheet.appendRow([for (final c in row) xlsx.TextCellValue(c)]);
    }

    for (final sec in d.extraSections) {
      sheet.appendRow([]);
      sheet.appendRow([xlsx.TextCellValue(sec.title)]);
      sheet.appendRow([for (final c in sec.columns) xlsx.TextCellValue(c)]);
      for (final row in sec.rows) {
        sheet.appendRow([for (final c in row) xlsx.TextCellValue(c)]);
      }
    }

    final bytes = excel.encode();
    if (bytes == null) throw StateError('Excel encode failed');
    final stem = _exportStem(d, tenantId);
    await _shareBytes(
      fileName: '$stem.xlsx',
      bytes: bytes,
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  static Future<void> exportCsv(ReportDataset d, {String? tenantId}) async {
    final buf = StringBuffer()
      ..writeln(_csvCell(AppConstants.appFullName))
      ..writeln(_csvCell(d.reportId.title))
      ..writeln(_csvCell('Period: ${d.rangeLabel}'))
      ..writeln(_csvCell('Filters: ${d.filterFootnote}'))
      ..writeln();

    buf.writeln(d.tableColumns.map(_csvCell).join(','));
    for (final row in d.tableRows) {
      buf.writeln(row.map(_csvCell).join(','));
    }

    for (final sec in d.extraSections) {
      buf.writeln();
      buf.writeln(_csvCell(sec.title));
      buf.writeln(sec.columns.map(_csvCell).join(','));
      for (final row in sec.rows) {
        buf.writeln(row.map(_csvCell).join(','));
      }
    }

    final stem = _exportStem(d, tenantId);
    await _shareBytes(
      fileName: '$stem.csv',
      bytes: buf.toString().codeUnits,
      mimeType: 'text/csv',
    );
  }

  static void logExportStart({required String slug, required String format, required String tenantId}) {
    KpmsReportLog.exportStarted(reportSlug: slug, format: format, tenantId: tenantId);
  }

  static void logExportDone({required String slug, required String format, required String tenantId}) {
    KpmsReportLog.exportCompleted(reportSlug: slug, format: format, tenantId: tenantId);
  }
}
