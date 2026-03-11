/**
 * Vercel AI SDK integration for remit.md.
 *
 * Usage with the Vercel AI SDK:
 *
 *   import { generateText } from "ai";
 *   import { anthropic } from "@ai-sdk/anthropic";
 *   import { Wallet } from "@remitmd/sdk";
 *   import { remitTools } from "@remitmd/sdk/integrations/vercel-ai";
 *
 *   const wallet = Wallet.fromEnv();
 *   const result = await generateText({
 *     model: anthropic("claude-opus-4-6"),
 *     tools: remitTools(wallet),
 *     prompt: "Pay agent@example.com $5 for the data analysis.",
 *   });
 *
 * Note: This module exports plain tool descriptors compatible with the AI SDK tool()
 * format. Import `tool` from "ai" and `z` from "zod" in your application — we don't
 * bundle them to avoid version conflicts.
 */

import type { Wallet } from "../wallet.js";

/** Parameter schema for a remit tool (zod-compatible shape description). */
interface ToolParam {
  type: "string" | "number" | "boolean";
  description: string;
  optional?: boolean;
}

/** Lightweight tool descriptor — compatible with Vercel AI SDK `tool()` format. */
export interface RemitToolDescriptor {
  description: string;
  parameters: Record<string, ToolParam>;
  execute: (...args: unknown[]) => Promise<unknown>;
}

/**
 * Returns remit.md payment tools configured for the given wallet.
 * Pass the result directly as the `tools` parameter to `generateText` / `streamText`.
 *
 * Compatible with Vercel AI SDK v3+. Each entry is a plain object with
 * `description`, `parameters`, and `execute` — wrap with `tool()` from "ai" if needed.
 */
export function remitTools(wallet: Wallet): Record<string, RemitToolDescriptor> {
  return {
    remit_pay_direct: {
      description:
        "Send a direct USDC payment to another agent or address. Use for simple transfers, tips, or one-time payments.",
      parameters: {
        to: { type: "string", description: "Recipient wallet address (0x...)" },
        amount: { type: "number", description: "Amount in USD (e.g. 5.00)" },
        memo: { type: "string", description: "Optional payment memo", optional: true },
      },
      execute: async (to: unknown, amount: unknown, memo?: unknown) =>
        wallet.payDirect(String(to), Number(amount), memo ? String(memo) : ""),
    },

    remit_check_balance: {
      description: "Check the current USDC balance of this wallet.",
      parameters: {},
      execute: async () => {
        const b = await wallet.balance();
        return { balance: b, currency: "USDC" };
      },
    },

    remit_get_status: {
      description: "Get detailed wallet status including tier, monthly volume, and fee rate.",
      parameters: {},
      execute: async () => wallet.status(),
    },

    remit_create_escrow: {
      description:
        "Fund an escrow for a task. Funds are held until the payee completes the work and you release them.",
      parameters: {
        to: { type: "string", description: "Payee wallet address" },
        amount: { type: "number", description: "Escrow amount in USD" },
        task: { type: "string", description: "Description of the task" },
        timeout: {
          type: "number",
          description: "Seconds until escrow expires (default 86400)",
          optional: true,
        },
      },
      execute: async (to: unknown, amount: unknown, task: unknown, timeout?: unknown) =>
        wallet.pay({
          id: `inv-${Date.now()}`,
          from: wallet.address,
          to: String(to),
          amount: Number(amount),
          chain: "base",
          status: "pending",
          paymentType: "escrow",
          memo: String(task),
          timeout: timeout ? Number(timeout) : 86400,
          createdAt: Math.floor(Date.now() / 1000),
        }),
    },

    remit_release_escrow: {
      description: "Release escrowed funds to the payee after verifying the work is complete.",
      parameters: {
        invoice_id: { type: "string", description: "Invoice ID of the escrow to release" },
      },
      execute: async (invoice_id: unknown) => wallet.releaseEscrow(String(invoice_id)),
    },

    remit_open_tab: {
      description:
        "Open a metered payment tab for pay-per-use services. The payee charges against the tab as the service is used.",
      parameters: {
        to: { type: "string", description: "Service provider wallet address" },
        limit: { type: "number", description: "Maximum total spend in USD" },
        per_unit: { type: "number", description: "Cost per unit of service in USD" },
        expires: {
          type: "number",
          description: "Tab lifetime in seconds (default 86400)",
          optional: true,
        },
      },
      execute: async (to: unknown, limit: unknown, per_unit: unknown, expires?: unknown) =>
        wallet.openTab({
          to: String(to),
          limit: Number(limit),
          perUnit: Number(per_unit),
          expires: expires ? Number(expires) : undefined,
        }),
    },

    remit_close_tab: {
      description: "Close a metered payment tab and settle final charges.",
      parameters: {
        tab_id: { type: "string", description: "Tab ID to close" },
      },
      execute: async (tab_id: unknown) => wallet.closeTab(String(tab_id)),
    },

    remit_open_stream: {
      description:
        "Start a streaming payment to an agent. Funds flow continuously at the specified rate.",
      parameters: {
        to: { type: "string", description: "Recipient wallet address" },
        rate: { type: "number", description: "Payment rate in USD per second" },
        max_duration: {
          type: "number",
          description: "Maximum stream duration in seconds (default 3600)",
          optional: true,
        },
        max_total: {
          type: "number",
          description: "Maximum total payment in USD",
          optional: true,
        },
      },
      execute: async (to: unknown, rate: unknown, max_duration?: unknown, max_total?: unknown) =>
        wallet.openStream({
          to: String(to),
          rate: Number(rate),
          maxDuration: max_duration ? Number(max_duration) : undefined,
          maxTotal: max_total ? Number(max_total) : undefined,
        }),
    },

    remit_close_stream: {
      description: "Stop a streaming payment. Unspent funds are returned to sender.",
      parameters: {
        stream_id: { type: "string", description: "Stream ID to close" },
      },
      execute: async (stream_id: unknown) => wallet.closeStream(String(stream_id)),
    },

    remit_post_bounty: {
      description:
        "Post an open bounty for any agent to claim. Funds are locked until you award a winner.",
      parameters: {
        amount: { type: "number", description: "Bounty amount in USD" },
        task: { type: "string", description: "Task description" },
        deadline: { type: "number", description: "Deadline as unix timestamp" },
        max_attempts: {
          type: "number",
          description: "Max number of submission attempts (default 10)",
          optional: true,
        },
      },
      execute: async (amount: unknown, task: unknown, deadline: unknown, max_attempts?: unknown) =>
        wallet.postBounty({
          amount: Number(amount),
          task: String(task),
          deadline: Number(deadline),
          maxAttempts: max_attempts ? Number(max_attempts) : undefined,
        }),
    },

    remit_place_deposit: {
      description:
        "Lock a refundable deposit with a counterparty as a performance bond or access credential.",
      parameters: {
        to: { type: "string", description: "Counterparty wallet address" },
        amount: { type: "number", description: "Deposit amount in USD" },
        expires: { type: "number", description: "Deposit lifetime in seconds" },
      },
      execute: async (to: unknown, amount: unknown, expires: unknown) =>
        wallet.placeDeposit({
          to: String(to),
          amount: Number(amount),
          expires: Number(expires),
        }),
    },
  };
}
