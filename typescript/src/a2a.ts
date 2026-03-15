/**
 * A2A / AP2 — agent card discovery and A2A JSON-RPC task client.
 *
 * Spec: https://google.github.io/A2A/specification/
 * AP2:  https://ap2-protocol.org/
 */

import type { Signer } from "./signer.js";
import { AuthenticatedClient } from "./http.js";
import { CHAIN_IDS } from "./client.js";

// ─── Agent Card types ─────────────────────────────────────────────────────────

export interface A2AExtension {
  uri: string;
  description: string;
  required: boolean;
}

export interface A2ACapabilities {
  streaming: boolean;
  pushNotifications: boolean;
  stateTransitionHistory: boolean;
  extensions: A2AExtension[];
}

export interface A2ASkill {
  id: string;
  name: string;
  description: string;
  tags: string[];
}

export interface A2AFees {
  standardBps: number;
  preferredBps: number;
  cliffUsd: number;
}

export interface A2AX402 {
  settleEndpoint: string;
  assets: Record<string, string>;
  fees: A2AFees;
}

export interface AgentCard {
  protocolVersion: string;
  name: string;
  description: string;
  /** A2A JSON-RPC endpoint URL (POST). */
  url: string;
  version: string;
  documentationUrl: string;
  capabilities: A2ACapabilities;
  authentication: unknown[];
  skills: A2ASkill[];
  x402: A2AX402;
}

/**
 * Fetch and parse the A2A agent card from `baseUrl`/.well-known/agent-card.json.
 *
 * @example
 * ```ts
 * const card = await discoverAgent("https://remit.md");
 * console.log(card.name, card.url);
 * ```
 */
export async function discoverAgent(baseUrl: string): Promise<AgentCard> {
  const url = baseUrl.replace(/\/$/, "") + "/.well-known/agent-card.json";
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) {
    throw new Error(`Agent card discovery failed: HTTP ${res.status} ${res.statusText}`);
  }
  return (await res.json()) as AgentCard;
}

// ─── A2A task types ───────────────────────────────────────────────────────────

export interface A2ATaskStatus {
  state: "completed" | "failed" | "canceled" | "working" | string;
  message?: { text?: string };
}

export interface A2AArtifactPart {
  kind: string;
  data?: Record<string, unknown>;
}

export interface A2AArtifact {
  name?: string;
  parts: A2AArtifactPart[];
}

export interface A2ATask {
  id: string;
  status: A2ATaskStatus;
  artifacts: A2AArtifact[];
}

/** Extract `txHash` from task artifacts, if present. */
export function getTaskTxHash(task: A2ATask): string | undefined {
  for (const artifact of task.artifacts) {
    for (const part of artifact.parts) {
      const tx = part.data?.["txHash"];
      if (typeof tx === "string") return tx;
    }
  }
  return undefined;
}

// ─── IntentMandate ────────────────────────────────────────────────────────────

export interface IntentMandate {
  mandateId: string;
  expiresAt: string;
  issuer: string;
  allowance: {
    maxAmount: string;
    currency: string;
  };
}

// ─── A2A client options ───────────────────────────────────────────────────────

export interface A2AClientOptions {
  /** Full A2A endpoint URL from the agent card (e.g. ``"https://remit.md/a2a"``). */
  endpoint: string;
  signer: Signer;
  chainId: number;
  verifyingContract?: string;
}

export interface SendOptions {
  to: string;
  amount: number;
  memo?: string;
  mandate?: IntentMandate;
}

// ─── A2A client ───────────────────────────────────────────────────────────────

/**
 * A2A JSON-RPC client — send payments and manage tasks via the A2A protocol.
 *
 * @example
 * ```ts
 * import { discoverAgent, A2AClient } from "@remitmd/sdk";
 * import { PrivateKeySigner } from "@remitmd/sdk";
 *
 * const card = await discoverAgent("https://remit.md");
 * const signer = new PrivateKeySigner(process.env.REMITMD_KEY!);
 * const client = A2AClient.fromCard(card, signer);
 * const task = await client.send({ to: "0xRecipient...", amount: 10 });
 * console.log(task.status.state, getTaskTxHash(task));
 * ```
 */
export class A2AClient {
  private readonly _http: AuthenticatedClient;
  private readonly _path: string;

  constructor(opts: A2AClientOptions) {
    const { endpoint, signer, chainId, verifyingContract = "" } = opts;
    const parsed = new URL(endpoint);
    const baseUrl = `${parsed.protocol}//${parsed.host}`;
    this._path = parsed.pathname || "/a2a";
    this._http = new AuthenticatedClient({ signer, baseUrl, chainId, verifyingContract });
  }

  /** Convenience constructor from an :class:`AgentCard` and a signer. */
  static fromCard(
    card: AgentCard,
    signer: Signer,
    opts?: { chain?: string; verifyingContract?: string },
  ): A2AClient {
    const chain = opts?.chain ?? "base";
    const chainId = CHAIN_IDS[chain] ?? CHAIN_IDS["base"]!;
    return new A2AClient({
      endpoint: card.url,
      signer,
      chainId,
      verifyingContract: opts?.verifyingContract ?? "",
    });
  }

  /**
   * Send a direct USDC payment via ``message/send``.
   *
   * @returns :interface:`A2ATask` with ``status.state === "completed"`` on success.
   */
  async send(opts: SendOptions): Promise<A2ATask> {
    const { to, amount, memo = "", mandate } = opts;
    const nonce = crypto.randomUUID().replace(/-/g, "");
    const messageId = crypto.randomUUID().replace(/-/g, "");

    const message: Record<string, unknown> = {
      messageId,
      role: "user",
      parts: [
        {
          kind: "data",
          data: {
            model: "direct",
            to,
            amount: amount.toFixed(2),
            memo,
            nonce,
          },
        },
      ],
    };

    if (mandate) {
      message["metadata"] = { mandate };
    }

    return this._rpc<A2ATask>("message/send", { message }, messageId);
  }

  /** Fetch the current state of an A2A task by ID. */
  async getTask(taskId: string): Promise<A2ATask> {
    return this._rpc<A2ATask>("tasks/get", { id: taskId }, taskId.slice(0, 16));
  }

  /** Cancel an in-progress A2A task. */
  async cancelTask(taskId: string): Promise<A2ATask> {
    return this._rpc<A2ATask>("tasks/cancel", { id: taskId }, taskId.slice(0, 16));
  }

  private async _rpc<T>(method: string, params: unknown, callId: string): Promise<T> {
    const body = { jsonrpc: "2.0", id: callId, method, params };
    const data = await this._http.post<{ result?: T; error?: { message?: string } }>(
      this._path,
      body,
    );
    if (data.error) {
      throw new Error(`A2A error: ${data.error.message ?? JSON.stringify(data.error)}`);
    }
    return (data.result ?? (data as unknown as T)) as T;
  }
}
