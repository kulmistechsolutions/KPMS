import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { hppGetTransaction, hasHppCredentials, isTimestampFresh, verifyWebhookSignature } from "../_shared/waafi_client.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-webhook-timestamp, x-webhook-event-id, x-webhook-signature",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: cors });
  }

  const rawBody = new Uint8Array(await req.arrayBuffer());
  const bodyText = new TextDecoder().decode(rawBody);
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(bodyText);
  } catch {
    return new Response("Invalid JSON", { status: 400, headers: cors });
  }

  const event = payload.event as string | undefined;

  // WaafiPay test ping during webhook registration
  if (event === "webhook.test") {
    return new Response("OK", { status: 200, headers: cors });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const webhookSecret = Deno.env.get("WAAFI_WEBHOOK_SECRET") ?? "";

  const timestamp = req.headers.get("X-Webhook-Timestamp") ?? "";
  const eventId = req.headers.get("X-Webhook-Event-Id") ?? "";
  const signature = req.headers.get("X-Webhook-Signature") ?? "";

  if (webhookSecret && event !== "webhook.test") {
    if (!timestamp || !eventId || !signature) {
      return new Response("Missing signature headers", { status: 401, headers: cors });
    }
    if (!isTimestampFresh(timestamp)) {
      return new Response("Stale webhook", { status: 401, headers: cors });
    }
    const valid = await verifyWebhookSignature(webhookSecret, timestamp, eventId, rawBody, signature);
    if (!valid) {
      return new Response("Invalid signature", { status: 401, headers: cors });
    }
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const payment = payload.payment as Record<string, unknown> | undefined;
  const referenceId = payment?.reference_id as string | undefined;
  const status = String(payment?.status ?? "").toUpperCase();
  const transactionId = payment?.transaction_id as string | undefined;
  const amount = payment?.amount as number | undefined;
  const currency = payment?.currency as string | undefined;

  if (!referenceId) {
    return new Response("OK", { status: 200, headers: cors });
  }

  const { data: payRow } = await admin
    .from("payments")
    .select("id, status, amount_cents, currency")
    .eq("waafi_reference_id", referenceId)
    .maybeSingle();

  if (!payRow) {
    console.error("Payment not found for reference", referenceId);
    return new Response("OK", { status: 200, headers: cors });
  }

  if (payRow.status === "paid") {
    return new Response("OK", { status: 200, headers: cors });
  }

  let finalStatus = "failed";
  if (status === "APPROVED") finalStatus = "paid";
  else if (["CANCELED", "CANCELLED"].includes(status)) finalStatus = "cancelled";
  else if (status === "REFUNDED") finalStatus = "refunded";

  // Server-side double-check with WAAFI inquiry when paid (HPP credentials only).
  if (finalStatus === "paid" && hasHppCredentials()) {
    try {
      const info = await hppGetTransaction(referenceId);
      const approved = String(info.status ?? info.tranStatusDesc ?? "").toLowerCase() === "approved";
      if (!approved) {
        finalStatus = "failed";
      }
    } catch (e) {
      console.error("WAAFI inquiry failed", e);
      finalStatus = "failed";
    }
  }

  const { error: rpcErr } = await admin.rpc("kpms_billing_complete_payment", {
    p_payment_id: payRow.id,
    p_waafi_transaction_id: transactionId ?? null,
    p_waafi_order_id: (payment?.order_id as string) ?? null,
    p_waafi_transfer_code: (payment?.transfer_code as string) ?? null,
    p_verified_amount: amount ?? payRow.amount_cents / 100,
    p_verified_currency: currency ?? payRow.currency,
    p_status: finalStatus,
    p_webhook_event_id: eventId || null,
    p_payload: payload,
  });

  if (rpcErr) {
    console.error("complete_payment failed", rpcErr);
    return new Response("Processing error", { status: 500, headers: cors });
  }

  return new Response("OK", { status: 200, headers: cors });
});
