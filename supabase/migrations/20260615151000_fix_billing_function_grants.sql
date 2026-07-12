-- Fix GRANT signatures for billing RPCs (prior migration had wrong arg count on complete_payment).

grant execute on function public.kpms_billing_complete_payment(uuid, text, text, text, numeric, text, text, text, jsonb) to service_role;

grant execute on function public.kpms_billing_run_daily_jobs() to service_role;
