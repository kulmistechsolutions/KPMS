import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import {
  apiPurchase,
  hasApiCredentials,
  hasHppCredentials,
  hppPurchase,
  normalizeMobileWalletAccount,
} from "../_shared/waafi_client.ts";

type Body = {
  plan_id: string;
  billing_interval?: "monthly" | "yearly";
  coupon_code?: string;
  payment_type?: string;
  payer_mobile?: string;
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");

  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  if (!body.plan_id) {
    return new Response(JSON.stringify({ error: "plan_id required" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  if (!hasHppCredentials() && !hasApiCredentials()) {
    return new Response(JSON.stringify({
      error: "WAAFI not configured — set API credentials (WAAFI_API_USER_ID + WAAFI_API_KEY) or HPP credentials (WAAFI_STORE_ID + WAAFI_HPP_KEY)",
    }), {
      status: 503,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const useApiPurchase = !hasHppCredentials() && hasApiCredentials();
  const payerMobileRaw = String(
    body.payer_mobile ?? (body as Record<string, unknown>).payerMobile ?? "",
  ).trim();
  const payerMobile = payerMobileRaw ? normalizeMobileWalletAccount(payerMobileRaw) : "";

  if (useApiPurchase && (!payerMobile || payerMobile.length < 10)) {
    return new Response(JSON.stringify({
      error: "Enter your WAAFI mobile wallet number (e.g. 252611111111) to pay via EVC/ZAAD.",
    }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const { data: checkout, error: checkoutErr } = await userClient.rpc("kpms_billing_create_checkout", {
    p_plan_id: body.plan_id,
    p_billing_interval: body.billing_interval ?? "monthly",
    p_coupon_code: body.coupon_code ?? null,
    p_payment_type: body.payment_type ?? "subscription_new",
  });

  if (checkoutErr || !checkout) {
    return new Response(JSON.stringify({ error: checkoutErr?.message ?? "Checkout failed" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const paymentId = checkout.payment_id as string;
  const referenceId = checkout.reference_id as string;
  const amountCents = checkout.amount_cents as number;
  const currency = (checkout.currency as string) ?? "USD";
  const planName = (checkout.plan_name as string) ?? "KPMS Subscription";
  const amount = amountCents / 100;
  const description = `KPMS ${planName}`;

  const markFailed = async (error: string) => {
    await admin.rpc("kpms_billing_complete_payment", {
      p_payment_id: paymentId,
      p_waafi_transaction_id: null,
      p_waafi_order_id: null,
      p_waafi_transfer_code: null,
      p_verified_amount: amount,
      p_verified_currency: currency,
      p_status: "failed",
      p_webhook_event_id: null,
      p_payload: { error },
    });
  };

  // ── API_PURCHASE (EVC/ZAAD direct) — uses API_USER_ID + API_KEY ──────────
  if (useApiPurchase) {
    try {
      const purchase = await apiPurchase({
        referenceId,
        amount,
        currency,
        description,
        accountNo: payerMobile,
      });

      const state = String(purchase.state ?? "").toUpperCase();
      if (state !== "APPROVED") {
        await markFailed(`WAAFI state: ${state || "unknown"}`);
        return new Response(JSON.stringify({
          error: `Payment not approved (${state || "unknown"}). Approve the prompt on your phone and try again.`,
        }), {
          status: 502,
          headers: { ...cors, "Content-Type": "application/json" },
        });
      }

      const { error: completeErr } = await admin.rpc("kpms_billing_complete_payment", {
        p_payment_id: paymentId,
        p_waafi_transaction_id: purchase.transactionId ?? null,
        p_waafi_order_id: purchase.issuerTransactionId ?? null,
        p_waafi_transfer_code: null,
        p_verified_amount: amount,
        p_verified_currency: currency,
        p_status: "paid",
        p_webhook_event_id: null,
        p_payload: { mode: "api_purchase", purchase },
      });

      if (completeErr) {
        return new Response(JSON.stringify({ error: completeErr.message }), {
          status: 500,
          headers: { ...cors, "Content-Type": "application/json" },
        });
      }

      return new Response(
        JSON.stringify({
          payment_id: paymentId,
          reference_id: referenceId,
          payment_mode: "api",
          status: "paid",
          transaction_id: purchase.transactionId,
          amount_cents: amountCents,
          currency,
        }),
        { status: 200, headers: { ...cors, "Content-Type": "application/json" } },
      );
    } catch (e) {
      await markFailed(String(e));
      return new Response(JSON.stringify({ error: String(e) }), {
        status: 502,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }
  }

  // ── HPP_PURCHASE (redirect to hosted page) — uses STORE_ID + HPP_KEY ─────
  const appBase = Deno.env.get("KPMS_APP_URL")
    ?? (Deno.env.get("VERCEL_URL") ? `https://${Deno.env.get("VERCEL_URL")}` : "http://localhost:8080");

  const successUrl = `${appBase}/app/subscriptions?payment=success&payment_id=${paymentId}`;
  const failureUrl = `${appBase}/app/subscriptions?payment=failed&payment_id=${paymentId}`;

  try {
    const hpp = await hppPurchase({
      referenceId,
      amount,
      currency,
      description,
      successUrl,
      failureUrl,
      payerMobile: payerMobile || undefined,
    });

    if (hpp.orderId) {
      await admin.from("payments").update({
        waafi_order_id: hpp.orderId,
        metadata: { hpp_url: hpp.hppUrl, mode: "hpp" },
        updated_at: new Date().toISOString(),
      }).eq("id", paymentId);
    }

    return new Response(
      JSON.stringify({
        payment_id: paymentId,
        reference_id: referenceId,
        payment_mode: "hpp",
        hpp_url: hpp.hppUrl,
        order_id: hpp.orderId,
        amount_cents: amountCents,
        currency,
      }),
      { status: 200, headers: { ...cors, "Content-Type": "application/json" } },
    );
  } catch (e) {
    await markFailed(String(e));
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 502,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
