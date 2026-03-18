package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** A submission against an open bounty. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class BountySubmission {

    @JsonProperty("id")
    public int id;

    @JsonProperty("bounty_id")
    public String bountyId;

    @JsonProperty("submitter")
    public String submitter;
}
