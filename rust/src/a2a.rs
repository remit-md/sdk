//! A2A / AP2 — agent card discovery and A2A JSON-RPC task client.
//!
//! Spec: <https://google.github.io/A2A/specification/>
//! AP2:  <https://ap2-protocol.org/>

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// A2A capability extension declared in an agent card.
#[derive(Debug, Clone, Deserialize)]
pub struct A2AExtension {
    pub uri: String,
    pub description: String,
    pub required: bool,
}

/// Capabilities block from an A2A agent card.
#[derive(Debug, Clone, Deserialize)]
pub struct A2ACapabilities {
    pub streaming: bool,
    #[serde(rename = "pushNotifications")]
    pub push_notifications: bool,
    #[serde(rename = "stateTransitionHistory")]
    pub state_transition_history: bool,
    pub extensions: Vec<A2AExtension>,
}

/// A single skill declared in an A2A agent card.
#[derive(Debug, Clone, Deserialize)]
pub struct A2ASkill {
    pub id: String,
    pub name: String,
    pub description: String,
    pub tags: Vec<String>,
}

/// Fee info block inside the x402 capability.
#[derive(Debug, Clone, Deserialize)]
pub struct A2AFees {
    #[serde(rename = "standardBps")]
    pub standard_bps: u32,
    #[serde(rename = "preferredBps")]
    pub preferred_bps: u32,
    #[serde(rename = "cliffUsd")]
    pub cliff_usd: u32,
}

/// x402 payment capability block in an agent card.
#[derive(Debug, Clone, Deserialize)]
pub struct A2AX402 {
    #[serde(rename = "settleEndpoint")]
    pub settle_endpoint: String,
    pub assets: HashMap<String, String>,
    pub fees: A2AFees,
}

/// A2A agent card parsed from `/.well-known/agent-card.json`.
#[derive(Debug, Clone, Deserialize)]
pub struct AgentCard {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    pub name: String,
    pub description: String,
    /// A2A JSON-RPC endpoint URL (POST).
    pub url: String,
    pub version: String,
    #[serde(rename = "documentationUrl")]
    pub documentation_url: String,
    pub capabilities: A2ACapabilities,
    pub skills: Vec<A2ASkill>,
    pub x402: A2AX402,
}

impl AgentCard {
    /// Fetch and parse the A2A agent card from
    /// `base_url/.well-known/agent-card.json`.
    ///
    /// ```ignore
    /// let card = remitmd::a2a::AgentCard::discover("https://remit.md").await?;
    /// println!("{} — {}", card.name, card.url);
    /// ```
    pub async fn discover(base_url: &str) -> Result<Self, crate::error::RemitError> {
        let url = format!(
            "{}/.well-known/agent-card.json",
            base_url.trim_end_matches('/')
        );
        let resp = reqwest::get(&url).await.map_err(|e| {
            crate::error::RemitError::new(
                crate::error::codes::NETWORK_ERROR,
                format!("Agent card discovery failed: {e}"),
            )
        })?;

        if !resp.status().is_success() {
            return Err(crate::error::RemitError::new(
                crate::error::codes::SERVER_ERROR,
                format!("Agent card discovery failed: HTTP {}", resp.status()),
            ));
        }

        let card: Self = resp.json().await.map_err(|e| {
            crate::error::RemitError::new(
                crate::error::codes::SERVER_ERROR,
                format!("Failed to parse agent card: {e}"),
            )
        })?;
        Ok(card)
    }
}

// ─── A2A task types ─────────────────────────────────────────────────────────

/// Status message within an A2A task.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct A2ATaskStatusMessage {
    #[serde(default)]
    pub text: Option<String>,
}

/// Status of an A2A task.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct A2ATaskStatus {
    pub state: String,
    #[serde(default)]
    pub message: Option<A2ATaskStatusMessage>,
}

/// A part within an A2A artifact.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct A2AArtifactPart {
    pub kind: String,
    #[serde(default)]
    pub data: Option<HashMap<String, serde_json::Value>>,
}

/// An artifact produced by an A2A task.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct A2AArtifact {
    #[serde(default)]
    pub name: Option<String>,
    pub parts: Vec<A2AArtifactPart>,
}

/// An A2A task returned by the JSON-RPC endpoint.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct A2ATask {
    pub id: String,
    pub status: A2ATaskStatus,
    #[serde(default)]
    pub artifacts: Vec<A2AArtifact>,
}

/// Extract `txHash` from task artifacts, if present.
pub fn get_task_tx_hash(task: &A2ATask) -> Option<String> {
    for artifact in &task.artifacts {
        for part in &artifact.parts {
            if let Some(data) = &part.data {
                if let Some(serde_json::Value::String(tx)) = data.get("txHash") {
                    return Some(tx.clone());
                }
            }
        }
    }
    None
}

// ─── IntentMandate ──────────────────────────────────────────────────────────

/// An intent mandate for authorized payments.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntentMandate {
    pub mandate_id: String,
    pub expires_at: String,
    pub issuer: String,
    pub allowance: IntentMandateAllowance,
}

/// Allowance within an intent mandate.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntentMandateAllowance {
    pub max_amount: String,
    pub currency: String,
}

// ─── A2AClient ──────────────────────────────────────────────────────────────

/// Options for creating an [`A2AClient`].
pub struct A2AClientOptions {
    /// Full A2A endpoint URL from the agent card (e.g. `"https://remit.md/a2a"`).
    pub endpoint: String,
    /// Signer for authenticating requests.
    pub signer: std::sync::Arc<dyn crate::signer::Signer>,
    /// Chain ID for EIP-712 signing.
    pub chain_id: u64,
    /// EIP-712 verifying contract address (optional).
    pub verifying_contract: Option<String>,
}

/// Options for sending a payment via A2A.
pub struct SendOptions {
    pub to: String,
    pub amount: f64,
    pub memo: Option<String>,
    pub mandate: Option<IntentMandate>,
}

/// A2A JSON-RPC client for sending payments and managing tasks.
///
/// ```rust,ignore
/// use remitmd::a2a::{AgentCard, A2AClient, get_task_tx_hash};
///
/// let card = AgentCard::discover("https://remit.md").await?;
/// let signer = remitmd::PrivateKeySigner::new("0x...")?;
/// let client = A2AClient::from_card(&card, std::sync::Arc::new(signer));
/// let task = client.send(SendOptions { to: "0x...".into(), amount: 10.0, memo: None, mandate: None }).await?;
/// println!("{} {:?}", task.status.state, get_task_tx_hash(&task));
/// ```
pub struct A2AClient {
    endpoint: String,
    client: reqwest::Client,
    _signer: std::sync::Arc<dyn crate::signer::Signer>,
}

impl A2AClient {
    /// Create a new A2A client from options.
    pub fn new(opts: A2AClientOptions) -> Self {
        Self {
            endpoint: opts.endpoint,
            client: reqwest::Client::new(),
            _signer: opts.signer,
        }
    }

    /// Convenience constructor from an [`AgentCard`] and a signer.
    pub fn from_card(card: &AgentCard, signer: std::sync::Arc<dyn crate::signer::Signer>) -> Self {
        Self {
            endpoint: card.url.clone(),
            client: reqwest::Client::new(),
            _signer: signer,
        }
    }

    /// Send a direct USDC payment via `message/send`.
    pub async fn send(&self, opts: SendOptions) -> Result<A2ATask, crate::error::RemitError> {
        let nonce = uuid::Uuid::new_v4().to_string().replace('-', "");
        let message_id = uuid::Uuid::new_v4().to_string().replace('-', "");

        let mut message = serde_json::json!({
            "messageId": message_id,
            "role": "user",
            "parts": [{
                "kind": "data",
                "data": {
                    "model": "direct",
                    "to": opts.to,
                    "amount": format!("{:.2}", opts.amount),
                    "memo": opts.memo.unwrap_or_default(),
                    "nonce": nonce,
                },
            }],
        });

        if let Some(mandate) = &opts.mandate {
            message["metadata"] = serde_json::json!({ "mandate": mandate });
        }

        self.rpc(
            "message/send",
            serde_json::json!({ "message": message }),
            &message_id,
        )
        .await
    }

    /// Fetch the current state of an A2A task by ID.
    pub async fn get_task(&self, task_id: &str) -> Result<A2ATask, crate::error::RemitError> {
        self.rpc(
            "tasks/get",
            serde_json::json!({ "id": task_id }),
            &task_id[..task_id.len().min(16)],
        )
        .await
    }

    /// Cancel an in-progress A2A task.
    pub async fn cancel_task(&self, task_id: &str) -> Result<A2ATask, crate::error::RemitError> {
        self.rpc(
            "tasks/cancel",
            serde_json::json!({ "id": task_id }),
            &task_id[..task_id.len().min(16)],
        )
        .await
    }

    async fn rpc(
        &self,
        method: &str,
        params: serde_json::Value,
        call_id: &str,
    ) -> Result<A2ATask, crate::error::RemitError> {
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": call_id,
            "method": method,
            "params": params,
        });

        let resp = self
            .client
            .post(&self.endpoint)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                crate::error::RemitError::new(
                    crate::error::codes::NETWORK_ERROR,
                    format!("A2A request failed: {e}"),
                )
            })?;

        let data: serde_json::Value = resp.json().await.map_err(|e| {
            crate::error::RemitError::new(
                crate::error::codes::SERVER_ERROR,
                format!("A2A response parse failed: {e}"),
            )
        })?;

        if let Some(error) = data.get("error") {
            let msg = error
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            return Err(crate::error::RemitError::new(
                crate::error::codes::SERVER_ERROR,
                format!("A2A error: {msg}"),
            ));
        }

        let result = data.get("result").unwrap_or(&data);
        serde_json::from_value(result.clone()).map_err(|e| {
            crate::error::RemitError::new(
                crate::error::codes::SERVER_ERROR,
                format!("A2A task parse failed: {e}"),
            )
        })
    }
}
