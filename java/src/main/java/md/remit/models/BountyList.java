package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/** Paginated list of bounties. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class BountyList {

    @JsonProperty("data")
    public List<Bounty> data;

    @JsonProperty("total")
    public int total;

    @JsonProperty("limit")
    public int limit;

    @JsonProperty("offset")
    public int offset;
}
