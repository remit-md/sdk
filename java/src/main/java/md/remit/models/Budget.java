package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;

/** Operator-set spending budget for this wallet. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Budget {

    @JsonProperty("daily_limit")
    public BigDecimal dailyLimit;

    @JsonProperty("daily_used")
    public BigDecimal dailyUsed;

    @JsonProperty("daily_remaining")
    public BigDecimal dailyRemaining;

    @JsonProperty("monthly_limit")
    public BigDecimal monthlyLimit;

    @JsonProperty("monthly_used")
    public BigDecimal monthlyUsed;

    @JsonProperty("monthly_remaining")
    public BigDecimal monthlyRemaining;

    @JsonProperty("per_tx_limit")
    public BigDecimal perTxLimit;
}
