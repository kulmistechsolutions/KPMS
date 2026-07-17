import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/medicine.dart';

final medicineCatalogProvider =
    StateNotifierProvider<MedicineCatalogNotifier, List<Medicine>>((ref) {
  return MedicineCatalogNotifier();
});

final lowStockMedicinesProvider = Provider<List<Medicine>>((ref) {
  final meds = ref.watch(medicineCatalogProvider);
  return meds.where((m) => m.isLowStock).toList();
});

class MedicineCatalogNotifier extends StateNotifier<List<Medicine>> {
  MedicineCatalogNotifier() : super(const []);

  Map<String, Medicine>? _idCache;

  void _invalidateIdCache() {
    _idCache = null;
  }

  /// Restore from disk (cold start).
  void replaceAll(List<Medicine> next) {
    _invalidateIdCache();
    state = List<Medicine>.from(next);
  }

  void reconcileWorkspace(List<Medicine> remote) => replaceAll(remote);

  /// Upsert catalog row from realtime; returns true when state changed.
  bool mergeWorkspaceEntity(Medicine incoming) {
    final idx = state.indexWhere((m) => m.id == incoming.id);
    if (idx < 0) {
      _invalidateIdCache();
      state = [incoming, ...state];
      return true;
    }
    final existing = state[idx];
    if (existing.quantity == incoming.quantity &&
        existing.sellingPrice == incoming.sellingPrice &&
        existing.buyingPrice == incoming.buyingPrice &&
        existing.name == incoming.name) {
      return false;
    }
    _invalidateIdCache();
    state = [
      for (final m in state)
        if (m.id == incoming.id) incoming else m,
    ];
    return true;
  }

  void removeWorkspaceEntity(String clientId) {
    _invalidateIdCache();
    state = state.where((m) => m.id != clientId).toList();
  }

  void addMedicine(Medicine m) {
    _invalidateIdCache();
    state = [m, ...state];
  }

  /// Bulk insert (e.g. CSV import) — single state update for the whole batch.
  void addMany(List<Medicine> meds) {
    if (meds.isEmpty) return;
    _invalidateIdCache();
    state = [...meds, ...state];
  }

  void updateMedicine(Medicine m) {
    _invalidateIdCache();
    state = [
      for (final x in state)
        if (x.id == m.id) m else x,
    ];
  }

  void removeMedicine(String id) {
    _invalidateIdCache();
    state = state.where((m) => m.id != id).toList();
  }

  Medicine? byId(String id) {
    _idCache ??= {for (final m in state) m.id: m};
    return _idCache![id];
  }

  /// Apply quantity delta after sale (local state until stock syncs from Supabase).
  void applySale(Map<String, int> qtyByMedicineId) {
    _invalidateIdCache();
    state = [
      for (final m in state)
        if (qtyByMedicineId.containsKey(m.id))
          m.copyWith(quantity: (m.quantity - (qtyByMedicineId[m.id] ?? 0)).clamp(0, 1 << 30))
        else
          m,
    ];
  }

  /// Restore stock after customer return.
  void applyReturnStock(Map<String, int> qtyByMedicineId) {
    _invalidateIdCache();
    state = [
      for (final m in state)
        if (qtyByMedicineId.containsKey(m.id))
          m.copyWith(quantity: m.quantity + (qtyByMedicineId[m.id] ?? 0))
        else
          m,
    ];
  }

  /// Remove stock when goods are returned to a supplier (RMA).
  void applySupplierReturn(Map<String, int> qtyByMedicineId) {
    _invalidateIdCache();
    state = [
      for (final m in state)
        if (qtyByMedicineId.containsKey(m.id))
          m.copyWith(quantity: (m.quantity - (qtyByMedicineId[m.id] ?? 0)).clamp(0, 1 << 30))
        else
          m,
    ];
  }

  /// Receiving a purchase: add quantity and refresh buying/selling prices (and expiry when set).
  void receivePurchase(List<PurchaseReceiveLine> lines) {
    _invalidateIdCache();
    final merged = <String, PurchaseReceiveLine>{};
    for (final l in lines) {
      final prev = merged[l.medicineId];
      if (prev == null) {
        merged[l.medicineId] = l;
      } else {
        merged[l.medicineId] = PurchaseReceiveLine(
          medicineId: l.medicineId,
          quantityAdded: prev.quantityAdded + l.quantityAdded,
          buyingPrice: l.buyingPrice,
          sellingPrice: l.sellingPrice,
          expiryDate: l.expiryDate ?? prev.expiryDate,
        );
      }
    }
    state = [
      for (final m in state)
        if (merged.containsKey(m.id))
          m.copyWith(
            quantity: m.quantity + merged[m.id]!.quantityAdded,
            buyingPrice: merged[m.id]!.buyingPrice,
            sellingPrice: merged[m.id]!.sellingPrice,
            expiryDate: merged[m.id]!.expiryDate ?? m.expiryDate,
          )
        else
          m,
    ];
  }
}

/// One catalog update from a purchase line.
class PurchaseReceiveLine {
  const PurchaseReceiveLine({
    required this.medicineId,
    required this.quantityAdded,
    required this.buyingPrice,
    required this.sellingPrice,
    this.expiryDate,
  });

  final String medicineId;
  final int quantityAdded;
  final double buyingPrice;
  final double sellingPrice;
  final DateTime? expiryDate;
}
