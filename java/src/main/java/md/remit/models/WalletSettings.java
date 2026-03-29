package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** Wallet display settings. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class WalletSettings {

    @JsonProperty("wallet")
    public String wallet;

    @JsonProperty("display_name")
    public String displayName;
}
