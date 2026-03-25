package md.remit.models;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

/** A funded escrow awaiting work completion. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Escrow {

    @JsonProperty("invoice_id")
    @JsonAlias("id")
    public String id;

    @JsonProperty("payer")
    public String payer;

    @JsonProperty("payee")
    public String payee;

    @JsonProperty("amount")
    public BigDecimal amount;

    @JsonProperty("fee")
    public BigDecimal fee;

    @JsonProperty("status")
    public String status; // "funded" | "released" | "cancelled"

    @JsonProperty("memo")
    public String memo;

    @JsonProperty("milestones")
    public List<Milestone> milestones;

    @JsonProperty("splits")
    public List<Split> splits;

    @JsonProperty("expires_at")
    public Instant expiresAt;

    @JsonProperty("created_at")
    public Instant createdAt;

    /** Individual payment milestone within an escrow. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Milestone {
        @JsonProperty("id")
        public String id;

        @JsonProperty("amount")
        public BigDecimal amount;

        @JsonProperty("description")
        public String description;

        @JsonProperty("status")
        public String status;
    }

    /** Split distribution within an escrow. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Split {
        @JsonProperty("recipient")
        @JsonAlias("address")
        public String recipient;

        @JsonProperty("basisPoints")
        @JsonAlias("bps")
        public int basisPoints; // basis points, 100 = 1%
    }
}
