import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_routes.dart';
import '../core/navigation/go_router_refresh.dart';
import '../core/navigation/kpms_destinations.dart';
import '../core/navigation/kpms_route_transitions.dart';
import '../core/auth/kpms_permission_gate.dart';
import '../core/supabase/auth_user_helpers.dart';
import '../core/supabase/pharmacy_operational_gate.dart';
import '../core/supabase/profile_tenant_gate.dart';
import '../core/supabase/supabase_bootstrap.dart';
import '../core/widgets/kpms_not_found_screen.dart';
import '../features/auth/presentation/forgot_password_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/reset_password_screen.dart';
import '../features/auth/presentation/verify_email_screen.dart';
import '../features/barcode/presentation/barcode_scanner_screen.dart';
import '../features/customers/presentation/customers_screen.dart';
import '../features/debts/presentation/customer_debt_invoice_screen.dart';
import '../features/debts/presentation/customer_debt_profile_screen.dart';
import '../features/debts/presentation/debts_dashboard_screen.dart';
import '../features/debts/presentation/supplier_finance_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/inventory/presentation/inventory_screen.dart';
import '../features/medicines/presentation/add_medicine_screen.dart';
import '../features/medicines/presentation/medicines_screen.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/pharmacy_access/presentation/pharmacy_access_blocked_screen.dart';
import '../features/prescriptions/presentation/prescriptions_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/purchases/presentation/purchase_returns_screen.dart';
import '../features/purchases/presentation/purchases_screen.dart';
import '../features/registration/presentation/pharmacy_registration_screen.dart';
import '../features/reports/presentation/sales_reports_screen.dart';
import '../features/reports/presentation/report_detail_screen.dart';
import '../features/enterprise/presentation/expenses_screen.dart';
import '../features/enterprise/presentation/medicine_categories_screen.dart';
import '../features/reports/presentation/reports_screen.dart';
import '../features/sales/presentation/checkout_screen.dart';
import '../features/sales/presentation/pos_screen.dart';
import '../features/sales/presentation/sales_returns_screen.dart';
import '../features/settings/presentation/settings_about_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/splash/presentation/branding_screen.dart';
import '../features/staff/domain/staff_member.dart';
import '../features/staff/presentation/join_staff_screen.dart';
import '../features/staff/presentation/staff_device_sessions_screen.dart';
import '../features/staff/presentation/staff_invite_screen.dart';
import '../features/staff/presentation/staff_create_screen.dart';
import '../features/staff/presentation/staff_edit_screen.dart';
import '../features/staff/presentation/staff_profile_screen.dart';
import '../features/staff/presentation/staff_screen.dart';
import '../features/subscriptions/presentation/subscriptions_screen.dart';
import '../features/suppliers/presentation/suppliers_screen.dart';
import '../features/transactions/presentation/transactions_screen.dart';
import '../features/super_admin/presentation/super_admin_audit_screen.dart';
import '../features/super_admin/presentation/super_admin_global_settings_screen.dart';
import '../features/super_admin/presentation/super_admin_pharmacy_detail_screen.dart';
import '../features/super_admin/presentation/super_admin_revenue_screen.dart';
import '../features/super_admin/presentation/super_admin_billing_center_screen.dart';
import '../features/super_admin/presentation/super_admin_users_screen.dart';
import '../features/super_admin/presentation/super_admin_announcements_screen.dart';
import '../features/super_admin/presentation/super_admin_dashboard_screen.dart';
import '../features/super_admin/presentation/super_admin_pharmacies_screen.dart';
import '../features/super_admin/presentation/super_admin_plans_screen.dart';
import '../features/super_admin/presentation/super_admin_login_screen.dart';
import '../features/super_admin/presentation/super_admin_monitoring_screen.dart';
import '../features/super_admin/presentation/super_admin_support_screen.dart';
import '../features/super_admin/presentation/super_admin_approvals_screen.dart';
import '../features/super_admin/presentation/super_admin_sessions_screen.dart';
import '../features/super_admin/presentation/super_admin_module_stub_screen.dart';
import '../l10n/app_localizations.dart';
import '../l10n/kpms_nav_l10n.dart';

bool _kpmsSubscriptionRouteLocked(String loc, PharmacyOperationalStatus op) {
  final f = op.featureFlags;
  if (f.isEmpty) return false;

  bool on(String k) {
    final v = f[k];
    if (v == false) return false;
    if (v is String && v.toLowerCase() == 'false') return false;
    return true;
  }

  if (!on('reports') && loc.startsWith(AppRoutes.reports)) return true;
  if (!on('enterprise') &&
      (loc.startsWith(AppRoutes.expenses) || loc.startsWith(AppRoutes.medicineCategories))) {
    return true;
  }
  if (!on('pos') && (loc.startsWith(AppRoutes.pos) || loc.startsWith(AppRoutes.checkout))) return true;
  return false;
}

CustomTransitionPage<void> _superAdminStubPage(
  GoRouterState state, {
  required KpmsNavId navId,
  required IconData icon,
  required String body,
}) {
  return kpmsSlideFadePage(
    state,
    Builder(
      builder: (context) {
        final l = AppLocalizations.of(context);
        return SuperAdminModuleStubScreen(
          title: navId.title(l),
          subtitle: navId.subtitle(l),
          icon: icon,
          body: body,
        );
      },
    ),
  );
}

const _publicPaths = <String>{
  AppRoutes.splash,
  AppRoutes.onboarding,
  AppRoutes.login,
  AppRoutes.forgotPassword,
  AppRoutes.resetPassword,
  AppRoutes.verifyEmail,
  AppRoutes.pharmacyRegistration,
  AppRoutes.joinStaff,
  AppRoutes.superAdminLogin,
};

/// Old mobile paths (pre [/app]) → namespaced pharmacy workspace.
String? _migrateLegacyPharmacyPath(String loc) {
  if (loc == AppRoutes.appRoot || loc == '${AppRoutes.appRoot}/') return AppRoutes.home;
  if (loc.startsWith(AppRoutes.appRoot)) return null;
  if (loc.startsWith(AppRoutes.superAdmin)) return null;
  if (_publicPaths.contains(loc)) return null;
  if (loc.startsWith(AppRoutes.joinStaff)) return null;
  if (loc == '/' || loc.isEmpty) return null;
  return '${AppRoutes.appRoot}$loc';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final client = SupabaseBootstrap.clientOrNull;
  final refresh = GoRouterRefreshStream(
    client?.auth.onAuthStateChange ?? const Stream<AuthState>.empty(),
  );
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: refresh,
    redirect: (context, state) async {
      final client = SupabaseBootstrap.clientOrNull;
      if (!SupabaseBootstrap.isConfigured || client == null) {
        return null;
      }

      final loc = state.matchedLocation;
      final migrated = _migrateLegacyPharmacyPath(loc);
      if (migrated != null) return migrated;

      final session = client.auth.currentSession;
      final user = kpmsAuthUser(client);
      final isPublic = _publicPaths.contains(loc);

      if (session == null || user == null) {
        ProfileTenantGate.invalidateTransientRoutingState();
        if (loc.startsWith(AppRoutes.superAdmin) && loc != AppRoutes.superAdminLogin) {
          return AppRoutes.superAdminLogin;
        }
        if (loc.startsWith(AppRoutes.appRoot)) {
          return AppRoutes.login;
        }
        if (isPublic) return null;
        return AppRoutes.login;
      }

      if (!kpmsEmailVerified(user) && loc != AppRoutes.verifyEmail) {
        final email = user.email ?? '';
        return '${AppRoutes.verifyEmail}?email=${Uri.encodeComponent(email)}';
      }

      final perm = await KpmsPermissionGate.resolve(client, user.id);

      if (loc == AppRoutes.appRoot || loc == '${AppRoutes.appRoot}/') {
        return perm.defaultLandingRoute;
      }

      if (kpmsEmailVerified(user) && loc == AppRoutes.verifyEmail) {
        if (perm.isPlatformSuperAdmin) return AppRoutes.superAdmin;
        final hasTenant = await ProfileTenantGate.hasTenantLinked(client, user.id);
        return hasTenant ? perm.defaultLandingRoute : AppRoutes.pharmacyRegistration;
      }

      if (perm.isPlatformSuperAdmin) {
        if (loc == AppRoutes.pharmacyRegistration) return AppRoutes.superAdmin;
        if (loc == AppRoutes.superAdminLogin) return AppRoutes.superAdmin;
        if (isPublic && (loc == AppRoutes.login || loc == AppRoutes.splash || loc == AppRoutes.onboarding)) {
          return AppRoutes.superAdmin;
        }
        if (!isPublic && !loc.startsWith(AppRoutes.superAdmin)) {
          return AppRoutes.superAdmin;
        }
        return null;
      }

      if (loc.startsWith(AppRoutes.superAdmin)) {
        return perm.safeFallbackRoute;
      }

      final hasTenant = await ProfileTenantGate.hasTenantLinked(client, user.id);
      if (!hasTenant) {
        if (loc == AppRoutes.pharmacyRegistration || loc == AppRoutes.forgotPassword) {
          return null;
        }
        if (loc == AppRoutes.login || loc == AppRoutes.splash || loc == AppRoutes.onboarding) {
          return AppRoutes.pharmacyRegistration;
        }
        if (!isPublic) {
          return AppRoutes.pharmacyRegistration;
        }
        return null;
      }

      final opGate = await PharmacyOperationalGate.resolve(client, user.id);
      if (loc == AppRoutes.pharmacyAccessBlocked) {
        if (!opGate.blocked) {
          return perm.defaultLandingRoute;
        }
        return null;
      }
      if (opGate.blocked && (loc.startsWith(AppRoutes.appRoot) || loc == AppRoutes.pharmacyRegistration)) {
        return AppRoutes.pharmacyAccessBlocked;
      }

      if (loc.startsWith(AppRoutes.appRoot) && !opGate.blocked && _kpmsSubscriptionRouteLocked(loc, opGate)) {
        return AppRoutes.home;
      }

      if (hasTenant &&
          !perm.isPlatformSuperAdmin &&
          perm.staffActive &&
          perm.mustChangePassword &&
          loc.startsWith(AppRoutes.appRoot) &&
          !loc.startsWith(AppRoutes.profile) &&
          !isPublic) {
        return AppRoutes.profile;
      }

      if (!perm.canAccessLocation(loc)) {
        return perm.safeFallbackRoute;
      }

      if (loc == AppRoutes.pharmacyRegistration) {
        return perm.defaultLandingRoute;
      }

      if (loc == AppRoutes.login || loc == AppRoutes.splash || loc == AppRoutes.onboarding) {
        return perm.defaultLandingRoute;
      }

      return null;
    },
    errorBuilder: (context, state) => KpmsNotFoundScreen(attemptedPath: state.uri.toString()),
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        name: 'splash',
        pageBuilder: (context, state) => kpmsFadePage(state, const BrandingScreen()),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        name: 'onboarding',
        pageBuilder: (context, state) => kpmsFadePage(state, const OnboardingScreen()),
      ),
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        pageBuilder: (context, state) => kpmsFadePage(state, const LoginScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminLogin,
        name: 'superAdminLogin',
        pageBuilder: (context, state) => kpmsFadePage(
          state,
          SuperAdminLoginScreen(initialEmail: state.uri.queryParameters['email']),
        ),
      ),
      GoRoute(
        path: AppRoutes.resetPassword,
        name: 'resetPassword',
        pageBuilder: (context, state) => kpmsFadePage(state, const ResetPasswordScreen()),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        name: 'forgotPassword',
        pageBuilder: (context, state) => kpmsFadePage(state, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: AppRoutes.verifyEmail,
        name: 'verifyEmail',
        pageBuilder: (context, state) => kpmsFadePage(state, const VerifyEmailScreen()),
      ),
      GoRoute(
        path: AppRoutes.pharmacyRegistration,
        name: 'pharmacyRegistration',
        pageBuilder: (context, state) => kpmsFadePage(state, const PharmacyRegistrationScreen()),
      ),
      GoRoute(
        path: AppRoutes.home,
        name: 'home',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const DashboardScreen()),
      ),
      GoRoute(
        path: AppRoutes.pharmacyAccessBlocked,
        name: 'pharmacyAccessBlocked',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const PharmacyAccessBlockedScreen()),
      ),
      GoRoute(
        path: AppRoutes.medicines,
        name: 'medicines',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const MedicinesScreen()),
      ),
      GoRoute(
        path: AppRoutes.addMedicine,
        name: 'addMedicine',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          AddMedicineScreen(
            initialBarcode: state.uri.queryParameters['barcode'],
            editMedicineId: state.uri.queryParameters['id'],
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.inventory,
        name: 'inventory',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const InventoryScreen()),
      ),
      GoRoute(
        path: AppRoutes.pos,
        name: 'pos',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const PosScreen()),
      ),
      GoRoute(
        path: AppRoutes.checkout,
        name: 'checkout',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const CheckoutScreen()),
      ),
      GoRoute(
        path: AppRoutes.salesReturns,
        name: 'salesReturns',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SalesReturnsScreen()),
      ),
      GoRoute(
        path: AppRoutes.purchases,
        name: 'purchases',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const PurchasesScreen()),
      ),
      GoRoute(
        path: AppRoutes.purchaseReturns,
        name: 'purchaseReturns',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const PurchaseReturnsScreen()),
      ),
      GoRoute(
        path: AppRoutes.suppliers,
        name: 'suppliers',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuppliersScreen()),
      ),
      GoRoute(
        path: AppRoutes.customers,
        name: 'customers',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const CustomersScreen()),
      ),
      GoRoute(
        path: AppRoutes.debts,
        name: 'debts',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const DebtsDashboardScreen()),
      ),
      GoRoute(
        path: '${AppRoutes.debts}/customer/:customerId',
        name: 'debtsCustomer',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          CustomerDebtProfileScreen(customerId: state.pathParameters['customerId']!),
        ),
      ),
      GoRoute(
        path: '${AppRoutes.debts}/invoice/:invoiceNumber',
        name: 'debtsInvoice',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          CustomerDebtInvoiceScreen(
            invoiceNumber: Uri.decodeComponent(state.pathParameters['invoiceNumber']!),
          ),
        ),
      ),
      GoRoute(
        path: '${AppRoutes.supplierFinance}/:supplierId',
        name: 'supplierFinance',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          SupplierFinanceScreen(supplierId: state.pathParameters['supplierId']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.prescriptions,
        name: 'prescriptions',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const PrescriptionsScreen()),
      ),
      GoRoute(
        path: '${AppRoutes.reports}/:reportSlug',
        name: 'reportDetail',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          state.pathParameters['reportSlug'] == 'sales'
              ? const SalesReportsScreen()
              : ReportDetailScreen(reportSlug: state.pathParameters['reportSlug']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.reports,
        name: 'reports',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const ReportsScreen()),
      ),
      GoRoute(
        path: AppRoutes.expenses,
        name: 'expenses',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const ExpensesScreen()),
      ),
      GoRoute(
        path: AppRoutes.medicineCategories,
        name: 'medicineCategories',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const MedicineCategoriesScreen()),
      ),
      GoRoute(
        path: AppRoutes.transactions,
        name: 'transactions',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const TransactionsScreen()),
      ),
      GoRoute(
        path: AppRoutes.subscriptions,
        name: 'subscriptions',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SubscriptionsScreen()),
      ),
      GoRoute(
        path: AppRoutes.profile,
        name: 'profile',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const ProfileScreen()),
        routes: [
          GoRoute(
            path: 'sessions',
            name: 'profileSessions',
            pageBuilder: (context, state) => kpmsSlideFadePage(state, const StaffDeviceSessionsScreen()),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.settings,
        name: 'settings',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SettingsScreen()),
        routes: [
          GoRoute(
            path: 'about',
            name: 'settingsAbout',
            pageBuilder: (context, state) => kpmsSlideFadePage(state, const SettingsAboutScreen()),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.notifications,
        name: 'notifications',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const NotificationsScreen()),
      ),
      GoRoute(
        path: AppRoutes.joinStaff,
        name: 'joinStaff',
        pageBuilder: (context, state) => kpmsFadePage(
          state,
          JoinStaffScreen(initialToken: state.uri.queryParameters['token']),
        ),
      ),
      GoRoute(
        path: AppRoutes.staffCreate,
        name: 'staffCreate',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const StaffCreateScreen()),
      ),
      GoRoute(
        path: AppRoutes.staffInvite,
        name: 'staffInvite',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const StaffInviteScreen()),
      ),
      GoRoute(
        path: '${AppRoutes.staff}/:staffId/edit',
        name: 'staffEdit',
        pageBuilder: (context, state) {
          final id = state.pathParameters['staffId']!;
          final extra = state.extra;
          final initial = extra is StaffMember ? extra : null;
          return kpmsSlideFadePage(state, StaffEditScreen(staffId: id, initial: initial));
        },
      ),
      GoRoute(
        path: '${AppRoutes.staff}/:staffId',
        name: 'staffProfile',
        pageBuilder: (context, state) {
          final id = state.pathParameters['staffId']!;
          return kpmsSlideFadePage(state, StaffProfileScreen(staffId: id));
        },
      ),
      GoRoute(
        path: AppRoutes.staff,
        name: 'staff',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const StaffScreen()),
      ),
      GoRoute(
        path: AppRoutes.barcodeScanner,
        name: 'barcodeScanner',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const BarcodeScannerScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdmin,
        name: 'superAdmin',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminDashboardScreen()),
      ),
      GoRoute(
        path: '${AppRoutes.superAdminPharmacies}/:tenantId',
        name: 'superAdminPharmacyDetail',
        pageBuilder: (context, state) => kpmsSlideFadePage(
          state,
          SuperAdminPharmacyDetailScreen(tenantId: state.pathParameters['tenantId']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.superAdminPharmacies,
        name: 'superAdminPharmacies',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminPharmaciesScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminPlans,
        name: 'superAdminPlans',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminPlansScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminSupport,
        name: 'superAdminSupport',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminSupportScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminAnnouncements,
        name: 'superAdminAnnouncements',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminAnnouncementsScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminRevenue,
        name: 'superAdminRevenue',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminRevenueScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminBilling,
        name: 'superAdminBilling',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminBillingCenterScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminUsers,
        name: 'superAdminUsers',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminUsersScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminApprovals,
        name: 'superAdminApprovals',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminApprovalsScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminAudit,
        name: 'superAdminAudit',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminAuditScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminSessions,
        name: 'superAdminSessions',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminSessionsScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminMonitoring,
        name: 'superAdminMonitoring',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminMonitoringScreen()),
      ),
      GoRoute(
        path: AppRoutes.superAdminGlobalSettings,
        name: 'superAdminGlobalSettings',
        pageBuilder: (context, state) => kpmsSlideFadePage(state, const SuperAdminGlobalSettingsScreen()),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
