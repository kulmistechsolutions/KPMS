import 'package:flutter/material.dart';

import '../auth/kpms_permission_context.dart';
import '../constants/app_routes.dart';

/// Single source of truth for “all pages” — drawer & dashboard modules.
enum KpmsNavZone {
  pharmacy,
  platform,
}

/// Stable ids for drawer / bottom nav localization.
enum KpmsNavId {
  dashboard,
  medicines,
  inventory,
  pos,
  salesReturns,
  debts,
  purchases,
  purchaseReturns,
  suppliers,
  customers,
  prescriptions,
  staff,
  reports,
  transactions,
  subscriptions,
  notifications,
  profile,
  settings,
  barcodeScanner,
  superHome,
  superPharmacies,
  superPlans,
  superSupport,
  superAnnouncements,
  superRevenue,
  superBilling,
  superUsers,
  superApprovals,
  superAudit,
  superSessions,
  superMonitoring,
  superGlobalSettings,
}

class KpmsDestination {
  const KpmsDestination({
    required this.route,
    required this.navId,
    required this.icon,
    required this.zone,
    this.requiresPharmacyAdmin = false,
  });

  final String route;
  final KpmsNavId navId;
  final IconData icon;
  final KpmsNavZone zone;

  /// When true, only [KpmsPermissionContext.isPharmacyAdminTier] users see this destination (cashier/staff hidden).
  final bool requiresPharmacyAdmin;
}

/// Logged-in pharmacy tenant destinations.
const List<KpmsDestination> kpmsPharmacyDestinations = [
  KpmsDestination(
    route: AppRoutes.home,
    navId: KpmsNavId.dashboard,
    icon: Icons.dashboard_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.medicines,
    navId: KpmsNavId.medicines,
    icon: Icons.medication_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.inventory,
    navId: KpmsNavId.inventory,
    icon: Icons.inventory_2_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.pos,
    navId: KpmsNavId.pos,
    icon: Icons.point_of_sale_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.salesReturns,
    navId: KpmsNavId.salesReturns,
    icon: Icons.assignment_return_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.debts,
    navId: KpmsNavId.debts,
    icon: Icons.account_balance_wallet_outlined,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.purchases,
    navId: KpmsNavId.purchases,
    icon: Icons.shopping_cart_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.purchaseReturns,
    navId: KpmsNavId.purchaseReturns,
    icon: Icons.keyboard_return_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.suppliers,
    navId: KpmsNavId.suppliers,
    icon: Icons.local_shipping_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.customers,
    navId: KpmsNavId.customers,
    icon: Icons.people_outline_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.prescriptions,
    navId: KpmsNavId.prescriptions,
    icon: Icons.medical_information_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.staff,
    navId: KpmsNavId.staff,
    icon: Icons.badge_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.reports,
    navId: KpmsNavId.reports,
    icon: Icons.analytics_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.transactions,
    navId: KpmsNavId.transactions,
    icon: Icons.receipt_long_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.subscriptions,
    navId: KpmsNavId.subscriptions,
    icon: Icons.subscriptions_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.notifications,
    navId: KpmsNavId.notifications,
    icon: Icons.notifications_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.profile,
    navId: KpmsNavId.profile,
    icon: Icons.person_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
  KpmsDestination(
    route: AppRoutes.settings,
    navId: KpmsNavId.settings,
    icon: Icons.settings_rounded,
    zone: KpmsNavZone.pharmacy,
    requiresPharmacyAdmin: true,
  ),
  KpmsDestination(
    route: AppRoutes.barcodeScanner,
    navId: KpmsNavId.barcodeScanner,
    icon: Icons.document_scanner_rounded,
    zone: KpmsNavZone.pharmacy,
  ),
];

/// Super Admin zone — never shown to pharmacy users.
const List<KpmsDestination> kpmsPlatformDestinations = [
  KpmsDestination(
    route: AppRoutes.superAdmin,
    navId: KpmsNavId.superHome,
    icon: Icons.admin_panel_settings_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminPharmacies,
    navId: KpmsNavId.superPharmacies,
    icon: Icons.storefront_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminPlans,
    navId: KpmsNavId.superPlans,
    icon: Icons.price_change_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminRevenue,
    navId: KpmsNavId.superRevenue,
    icon: Icons.insights_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminBilling,
    navId: KpmsNavId.superBilling,
    icon: Icons.payments_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminApprovals,
    navId: KpmsNavId.superApprovals,
    icon: Icons.verified_user_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminUsers,
    navId: KpmsNavId.superUsers,
    icon: Icons.groups_2_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminSupport,
    navId: KpmsNavId.superSupport,
    icon: Icons.support_agent_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminAnnouncements,
    navId: KpmsNavId.superAnnouncements,
    icon: Icons.campaign_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminAudit,
    navId: KpmsNavId.superAudit,
    icon: Icons.history_edu_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminSessions,
    navId: KpmsNavId.superSessions,
    icon: Icons.devices_other_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminMonitoring,
    navId: KpmsNavId.superMonitoring,
    icon: Icons.monitor_heart_rounded,
    zone: KpmsNavZone.platform,
  ),
  KpmsDestination(
    route: AppRoutes.superAdminGlobalSettings,
    navId: KpmsNavId.superGlobalSettings,
    icon: Icons.tune_rounded,
    zone: KpmsNavZone.platform,
  ),
];

/// Pharmacy grid filtered by RBAC + per-staff [StaffFeatureAccess].
List<KpmsDestination> visiblePharmacyDestinations(KpmsPermissionContext ctx) {
  if (ctx.isPlatformSuperAdmin) return const [];
  if (!ctx.staffActive) return const [];
  if (ctx.isPharmacyAdminTier) {
    return kpmsPharmacyDestinations
        .where((d) => !d.requiresPharmacyAdmin || ctx.isPharmacyAdminTier)
        .toList(growable: false);
  }
  return kpmsPharmacyDestinations.where((d) => ctx.canAccessLocation(d.route)).toList(growable: false);
}
