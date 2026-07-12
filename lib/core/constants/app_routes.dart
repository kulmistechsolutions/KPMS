/// Named routes for KPMS — pharmacy app under [/app], platform admin under [/super-admin].
abstract final class AppRoutes {
  /// Authenticated pharmacy workspace (mobile-first). Public auth stays at root.
  static const String appRoot = '/app';

  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String forgotPassword = '/forgot-password';
  static const String verifyEmail = '/verify-email';
  static const String resetPassword = '/reset-password';
  static const String pharmacyRegistration = '/register-pharmacy';
  static const String joinStaff = '/join-staff';

  /// Shown when the tenant is suspended, archived, subscription expired, or platform maintenance.
  static const String pharmacyAccessBlocked = '/app/access-blocked';

  static const String home = '/app/home';
  static const String medicines = '/app/medicines';
  static const String addMedicine = '/app/medicines/add';
  static const String inventory = '/app/inventory';
  static const String pos = '/app/pos';
  static const String checkout = '/app/checkout';
  static const String salesReturns = '/app/sales-returns';
  static const String purchases = '/app/purchases';
  static const String purchaseReturns = '/app/purchase-returns';
  static const String suppliers = '/app/suppliers';
  static const String customers = '/app/customers';
  static const String debts = '/app/debts';
  static const String supplierFinance = '/app/supplier-finance';
  static const String prescriptions = '/app/prescriptions';
  static const String reports = '/app/reports';
  static const String expenses = '/app/expenses';
  static const String medicineCategories = '/app/medicine-categories';
  static const String transactions = '/app/transactions';

  /// Deep link to analytics workspace for a [KpmsReportId.slug].
  static String reportDetail(String reportSlug) => '$reports/$reportSlug';
  static const String subscriptions = '/app/subscriptions';
  static const String settings = '/app/settings';
  static const String settingsAbout = '/app/settings/about';
  static const String profile = '/app/profile';
  static const String profileSessions = '/app/profile/sessions';
  static const String notifications = '/app/notifications';
  static const String staff = '/app/staff';
  static const String staffCreate = '/app/staff/create';
  static const String staffInvite = '/app/staff/invite';
  static String staffProfile(String staffId) => '/app/staff/$staffId';
  static String staffEdit(String staffId) => '/app/staff/$staffId/edit';
  static const String barcodeScanner = '/app/barcode-scanner';

  static String debtsCustomerProfile(String customerId) => '$debts/customer/$customerId';
  static String debtsInvoice(String invoiceNumber) => '$debts/invoice/${Uri.encodeComponent(invoiceNumber)}';

  /// Platform operator console (web-style shell). Not for pharmacy staff.
  static const String superAdminLogin = '/super-admin/login';
  static const String superAdmin = '/super-admin';
  static const String superAdminPharmacies = '/super-admin/pharmacies';

  static String superAdminPharmacyDetail(String tenantId) => '$superAdminPharmacies/$tenantId';
  static const String superAdminPlans = '/super-admin/plans';
  static const String superAdminSupport = '/super-admin/support';
  static const String superAdminAnnouncements = '/super-admin/announcements';

  /// Platform SaaS modules (stubs until operator backend is wired).
  static const String superAdminRevenue = '/super-admin/revenue';
  static const String superAdminBilling = '/super-admin/billing';
  static const String superAdminUsers = '/super-admin/users';
  static const String superAdminApprovals = '/super-admin/approvals';
  static const String superAdminAudit = '/super-admin/audit';
  static const String superAdminSessions = '/super-admin/sessions';
  static const String superAdminMonitoring = '/super-admin/monitoring';
  static const String superAdminGlobalSettings = '/super-admin/global-settings';
}
