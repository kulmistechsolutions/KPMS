/// Global app constants for KPMS (KULMIS Pharmacy Management System).
abstract final class AppConstants {
  static const String appName = 'KPMS';
  static const String appFullName = 'KULMIS Pharmacy Management System';
  static const String tagline = 'Modern pharmacy operations, secured in the cloud.';

  /// Upper bound for a single auth/routing gate DB call (permission, tenant,
  /// operational-status). These run inside the GoRouter `redirect`, which holds
  /// navigation on the splash screen until it resolves — so an un-bounded call on a
  /// stalled network would leave the user stuck on the splash indefinitely. On
  /// timeout each gate's existing catch path falls back to sticky/cached/safe state.
  static const Duration authGateNetworkTimeout = Duration(seconds: 6);

  /// Upper bound for a single page of a tenant workspace pull (up to [pageSize] rows).
  /// The bootstrap provider awaits the full pull with no outer timeout, so an
  /// un-bounded page fetch on a stalled connection would leave
  /// `pharmacyWorkspaceBootstrapReadyProvider` false forever (the app hangs on
  /// "loading workspace"). On timeout the pull throws and the bootstrap provider's
  /// catch falls back to the local cache. Larger than [authGateNetworkTimeout]
  /// because an 800-row page legitimately takes longer than a small auth RPC.
  static const Duration workspacePullPageTimeout = Duration(seconds: 20);
}
