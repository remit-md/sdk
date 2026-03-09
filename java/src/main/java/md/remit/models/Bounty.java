package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** A USDC bounty posted for task completion. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Bounty {

    @JsonProperty("id")
    public String id;

    @JsonProperty("poster")
    public String poster;

    @JsonProperty("award")
    public BigDecimal award;

    @JsonProperty("description")
    public String description;

    @JsonProperty("status")
    public String status; // "open" | "awarded" | "expired"

    @JsonProperty("winner")
    public String winner;

    @JsonProperty("expires_at")
    public Instant expiresAt;

    @JsonProperty("created_at")
    public Instant createdAt;
}
