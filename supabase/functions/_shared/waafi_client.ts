const WAAFI_ASM_URL = Deno.env.get("WAAFI_ASM_URL") ?? "https://api.waafipay.com/asm";

export type WaafiHppCredentials = {
  merchantUid: string;
  storeId: string;
  hppKey: string;
};

export type WaafiApiCredentials = {
  merchantUid: string;
  apiUserId: string;
  apiKey: string;
};

/** HPP checkout — needs WAAFI_STORE_ID + WAAFI_HPP_KEY (HPP-… prefix). */
export function hasHppCredentials(): boolean {
  const merchantUid = Deno.env.get("WAAFI_MERCHANT_UID") ?? "";
  const storeId = Deno.env.get("WAAFI_STORE_ID") ?? "";
  const hppKey = Deno.env.get("WAAFI_HPP_KEY") ?? "";
  return !!(merchantUid && storeId && hppKey);
}

/** Direct mobile-wallet charge — uses WAAFI_API_USER_ID + WAAFI_API_KEY (API-… prefix). */
export function hasApiCredentials(): boolean {
  const merchantUid = Deno.env.get("WAAFI_MERCHANT_UID") ?? "";
  const apiUserId = Deno.env.get("WAAFI_API_USER_ID") ?? "";
  const apiKey = Deno.env.get("WAAFI_API_KEY") ?? "";
  return !!(merchantUid && apiUserId && apiKey);
}

export function hppCredentials(): WaafiHppCredentials {
  const merchantUid = Deno.env.get("WAAFI_MERCHANT_UID") ?? "";
  const storeId = Deno.env.get("WAAFI_STORE_ID") ?? "";
  const hppKey = Deno.env.get("WAAFI_HPP_KEY") ?? "";
  if (!merchantUid || !storeId || !hppKey) {
    throw new Error("HPP credentials missing — set WAAFI_MERCHANT_UID, WAAFI_STORE_ID, WAAFI_HPP_KEY");
  }
  return { merchantUid, storeId, hppKey };
}

export function apiCredentials(): WaafiApiCredentials {
  const merchantUid = Deno.env.get("WAAFI_MERCHANT_UID") ?? "";
  const apiUserId = Deno.env.get("WAAFI_API_USER_ID") ?? "";
  const apiKey = Deno.env.get("WAAFI_API_KEY") ?? "";
  if (!merchantUid || !apiUserId || !apiKey) {
    throw new Error("API credentials missing — set WAAFI_MERCHANT_UID, WAAFI_API_USER_ID, WAAFI_API_KEY");
  }
  return { merchantUid, apiUserId, apiKey };
}

/** Somalia mobile: 252611111111 (no +, no leading 0). */
export function normalizeMobileWalletAccount(raw: string): string {
  let m = raw.replace(/[\s+\-()]/g, "");
  if (m.startsWith("00")) m = m.slice(2);
  if (m.startsWith("0") && m.length >= 9) m = `252${m.slice(1)}`;
  return m;
}

export function waafiTimestamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export async function waafiPost(serviceName: string, serviceParams: Record<string, unknown>) {
  const body = {
    schemaVersion: "1.0",
    requestId: crypto.randomUUID(),
    timestamp: waafiTimestamp(),
    channelName: "WEB",
    serviceName,
    serviceParams,
  };

  const res = await fetch(WAAFI_ASM_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body),
  });

  const json = await res.json();
  if (!res.ok) {
    throw new Error(`WAAFI HTTP ${res.status}: ${JSON.stringify(json)}`);
  }
  if (json.errorCode !== "0" && json.errorCode !== 0) {
    throw new Error(`WAAFI error ${json.errorCode}: ${json.responseMsg ?? "unknown"}`);
  }
  return json;
}

export async function hppPurchase(params: {
  referenceId: string;
  amount: number;
  currency: string;
  description: string;
  successUrl: string;
  failureUrl: string;
  payerMobile?: string;
}) {
  const creds = hppCredentials();
  const payerInfo: Record<string, string> = {};
  if (params.payerMobile) {
    payerInfo.subscriptionId = normalizeMobileWalletAccount(params.payerMobile);
  }

  const json = await waafiPost("HPP_PURCHASE", {
    merchantUid: creds.merchantUid,
    storeId: Number(creds.storeId),
    hppKey: creds.hppKey,
    paymentMethod: "MWALLET_ACCOUNT",
    hppSuccessCallbackUrl: params.successUrl,
    hppFailureCallbackUrl: params.failureUrl,
    hppRespDataFormat: 1,
    payerInfo,
    transactionInfo: {
      referenceId: params.referenceId,
      amount: params.amount,
      currency: params.currency,
      description: params.description,
    },
  });
  return json.params as { hppUrl?: string; orderId?: string; referenceId?: string };
}

/** Direct charge to EVC/ZAAD wallet — customer approves on their phone. */
export async function apiPurchase(params: {
  referenceId: string;
  amount: number;
  currency: string;
  description: string;
  accountNo: string;
}) {
  const creds = apiCredentials();
  const accountNo = normalizeMobileWalletAccount(params.accountNo);
  const json = await waafiPost("API_PURCHASE", {
    merchantUid: creds.merchantUid,
    apiUserId: creds.apiUserId,
    apiKey: creds.apiKey,
    paymentMethod: "MWALLET_ACCOUNT",
    payerInfo: { accountNo },
    transactionInfo: {
      referenceId: params.referenceId,
      invoiceId: params.referenceId,
      amount: params.amount,
      currency: params.currency,
      description: params.description,
    },
  });
  return json.params as {
    state?: string;
    transactionId?: string;
    referenceId?: string;
    txAmount?: string;
    issuerTransactionId?: string;
  };
}

export async function hppGetTransaction(referenceId: string) {
  const creds = hppCredentials();
  const json = await waafiPost("HPP_GETTRANINFO", {
    merchantUid: creds.merchantUid,
    storeId: Number(creds.storeId),
    hppKey: creds.hppKey,
    referenceId,
  });
  return json.params as Record<string, unknown>;
}

/** HMAC-SHA256 webhook verification per WaafiPay docs. */
export async function verifyWebhookSignature(
  secret: string,
  timestamp: string,
  eventId: string,
  rawBody: Uint8Array,
  signatureHex: string,
): Promise<boolean> {
  const enc = new TextEncoder();
  const signingString = `${timestamp}.${eventId}.${new TextDecoder().decode(rawBody)}`;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(signingString));
  const computed = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (computed.length !== signatureHex.length) return false;
  let diff = 0;
  for (let i = 0; i < computed.length; i++) {
    diff |= computed.charCodeAt(i) ^ signatureHex.charCodeAt(i);
  }
  return diff === 0;
}

export function isTimestampFresh(timestampSec: string, maxAgeSec = 300): boolean {
  const ts = Number(timestampSec);
  if (!Number.isFinite(ts)) return false;
  const now = Math.floor(Date.now() / 1000);
  return Math.abs(now - ts) <= maxAgeSec;
}
