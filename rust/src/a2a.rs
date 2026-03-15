//! A2A / AP2 — agent card discovery.
//!
//! Spec: <https://google.github.io/A2A/specification/>
//! AP2:  <https://ap2-protocol.org/>

use std::collections::HashMap;

use serde::Deserialize;

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
    /// ```no_run
    /// # tokio_test::block_on(async {
    /// let card = remitmd::a2a::AgentCard::discover("https://remit.md").await.unwrap();
    /// println!("{} — {}", card.name, card.url);
    /// # });
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
