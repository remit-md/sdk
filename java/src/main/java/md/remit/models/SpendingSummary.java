package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;

/** Spending analytics for a wallet over a period. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class SpendingSummary {

    @JsonProperty("address")
    public String address;

    @JsonProperty("period")
    public String period; // "day" | "week" | "month" | "all"

    @JsonProperty("total_spent")
    public BigDecimal totalSpent;

    @JsonProperty("total_fees")
    public BigDecimal totalFees;

    @JsonProperty("tx_count")
    public int txCount;
}
