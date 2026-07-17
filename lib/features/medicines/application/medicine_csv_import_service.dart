import 'package:csv/csv.dart';

import '../domain/medicine.dart';
import '../domain/medicine_form_type.dart';

/// One rejected CSV row, 1-based and counted against the whole file
/// (the header is row 1) so it matches what the user sees in a spreadsheet.
class MedicineImportRowError {
  const MedicineImportRowError({required this.row, required this.reason});

  final int row;
  final String reason;
}

class MedicineImportParseResult {
  const MedicineImportParseResult({
    required this.medicines,
    required this.errors,
    required this.totalDataRows,
  });

  final List<Medicine> medicines;
  final List<MedicineImportRowError> errors;

  /// Non-blank data rows found (excludes the header row).
  final int totalDataRows;

  bool get hasValidRows => medicines.isNotEmpty;
}

/// Thrown when the header row can't be mapped to the expected columns at all.
class MedicineImportHeaderException implements Exception {
  const MedicineImportHeaderException(this.message);
  final String message;
}

/// Parses a "Medicine Name, Batch Number, Expiry Date, Quantity, Buying Price,
/// Selling Price, Min Stock Level" CSV export into [Medicine] rows.
///
/// Column order is flexible — headers are matched by name (case/spacing
/// insensitive), not position — but the first row must be a header row.
abstract final class MedicineCsvImportService {
  MedicineCsvImportService._();

  static const Map<String, List<String>> _headerSynonyms = {
    'name': ['medicine name', 'name', 'medicine', 'item name', 'product name'],
    'batch': ['batch number', 'batch no', 'batch code', 'batch'],
    'expiry': ['expiry date', 'expiry', 'expiration date', 'exp date', 'exp'],
    'quantity': ['quantity', 'qty', 'stock', 'stock qty'],
    'buying': ['buying price', 'buy price', 'cost price', 'purchase price', 'unit cost'],
    'selling': ['selling price', 'sell price', 'sale price', 'unit price', 'retail price'],
    'minStock': ['min stock level', 'minimum stock', 'min stock', 'reorder level', 'low stock alert'],
  };

  static String _normalize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static Map<String, int> _mapHeaders(List<dynamic> headerRow) {
    final normalized = headerRow.map((c) => _normalize('$c')).toList();
    final map = <String, int>{};
    for (final entry in _headerSynonyms.entries) {
      for (final syn in entry.value) {
        final idx = normalized.indexOf(syn);
        if (idx != -1) {
          map[entry.key] = idx;
          break;
        }
      }
    }
    return map;
  }

  static String _cell(List<dynamic> row, int? idx) {
    if (idx == null || idx >= row.length) return '';
    return '${row[idx]}'.trim();
  }

  static double? _parsePrice(String raw) {
    if (raw.isEmpty) return null;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  static DateTime? _parseExpiry(String raw) {
    if (raw.isEmpty) return null;
    final iso = DateTime.tryParse(raw);
    if (iso != null) return iso;

    final parts = raw.split(RegExp(r'[\/\-.]')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 3) {
      final nums = parts.map((p) => int.tryParse(p)).toList();
      if (nums.every((n) => n != null)) {
        final a = nums[0]!, b = nums[1]!, c = nums[2]!;
        // yyyy/MM/dd
        if (a > 31) return DateTime.tryParse('${a.toString().padLeft(4, '0')}-${b.toString().padLeft(2, '0')}-${c.toString().padLeft(2, '0')}');
        // dd/MM/yyyy (day-first is the common non-US convention)
        if (c > 31) return DateTime.tryParse('${c.toString().padLeft(4, '0')}-${b.toString().padLeft(2, '0')}-${a.toString().padLeft(2, '0')}');
      }
    }
    return null;
  }

  static MedicineImportParseResult parse(String csvText) {
    final cleaned = csvText.replaceFirst('﻿', '').trim();
    if (cleaned.isEmpty) {
      throw const MedicineImportHeaderException('The file is empty.');
    }

    final rows = Csv(autoDetect: true)
        .decode(cleaned)
        .where((r) => r.any((c) => '$c'.trim().isNotEmpty))
        .toList();

    if (rows.isEmpty) {
      throw const MedicineImportHeaderException('The file is empty.');
    }

    final headerIdx = _mapHeaders(rows.first);
    if (!headerIdx.containsKey('name') ||
        !headerIdx.containsKey('quantity') ||
        !headerIdx.containsKey('buying') ||
        !headerIdx.containsKey('selling')) {
      throw const MedicineImportHeaderException(
        'Could not find the required columns. The first row must contain headers: '
        'Medicine Name, Quantity, Buying Price, Selling Price (Batch Number, Expiry Date, '
        'Min Stock Level are optional).',
      );
    }

    final dataRows = rows.skip(1).toList();
    final medicines = <Medicine>[];
    final errors = <MedicineImportRowError>[];
    final baseId = DateTime.now().microsecondsSinceEpoch;

    for (var i = 0; i < dataRows.length; i++) {
      final row = dataRows[i];
      final sheetRow = i + 2; // +1 for header, +1 for 1-based

      final name = _cell(row, headerIdx['name']);
      if (name.isEmpty) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Medicine name is required'));
        continue;
      }

      final qtyRaw = _cell(row, headerIdx['quantity']);
      final qty = qtyRaw.isEmpty ? 0 : int.tryParse(qtyRaw.replaceAll(',', ''));
      if (qty == null) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Quantity "$qtyRaw" is not a whole number'));
        continue;
      }

      final buyRaw = _cell(row, headerIdx['buying']);
      final buy = _parsePrice(buyRaw);
      if (buy == null) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Buying price "$buyRaw" is not a valid number'));
        continue;
      }

      final sellRaw = _cell(row, headerIdx['selling']);
      final sell = _parsePrice(sellRaw);
      if (sell == null) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Selling price "$sellRaw" is not a valid number'));
        continue;
      }

      if (sell < buy) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Selling price cannot be below buying price'));
        continue;
      }

      final minStockRaw = _cell(row, headerIdx['minStock']);
      final minStock = minStockRaw.isEmpty ? 0 : int.tryParse(minStockRaw.replaceAll(',', ''));
      if (minStock == null) {
        errors.add(MedicineImportRowError(row: sheetRow, reason: 'Min stock level "$minStockRaw" is not a whole number'));
        continue;
      }

      final expiryRaw = _cell(row, headerIdx['expiry']);
      DateTime? expiry;
      if (expiryRaw.isNotEmpty) {
        expiry = _parseExpiry(expiryRaw);
        if (expiry == null) {
          errors.add(MedicineImportRowError(row: sheetRow, reason: 'Expiry date "$expiryRaw" — use YYYY-MM-DD'));
          continue;
        }
      }

      final batchRaw = _cell(row, headerIdx['batch']);

      medicines.add(Medicine(
        id: 'med_${baseId}_$i',
        name: name,
        expiryDate: expiry,
        formType: MedicineFormType.tablet,
        quantity: qty,
        buyingPrice: buy,
        sellingPrice: sell,
        minimumStockAlert: minStock,
        batchCode: batchRaw.isEmpty ? null : batchRaw,
      ));
    }

    return MedicineImportParseResult(
      medicines: medicines,
      errors: errors,
      totalDataRows: dataRows.length,
    );
  }
}
