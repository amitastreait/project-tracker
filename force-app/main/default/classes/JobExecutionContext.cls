/**
 * JobExecutionContext
 *
 * Immutable value object passed into every job at dispatch time.
 * Carries all runtime information the job needs without it having to query anything itself.
 *
 * sharedContext is a read/write map persisted to JobPipelineRun__c.ContextData__c (JSON).
 * Jobs can write values that downstream steps can read in subsequent orchestrator passes.
 */
public class JobExecutionContext {

    /** Salesforce ID of the parent JobPipelineRun__c record. */
    public Id pipelineRunId { get; set; }

    /** Salesforce ID of this step's JobStepExecution__c record. */
    public Id stepExecutionId { get; set; }

    /** DeveloperName of the JobStep__mdt this execution corresponds to. */
    public String stepDeveloperName { get; set; }

    /** DeveloperName of the JobPipeline__mdt this run belongs to. */
    public String pipelineDeveloperName { get; set; }

    /**
     * Key-value parameters deserialized from JobStep__mdt.ExecutionParameters__c (JSON).
     * Read-only at runtime — set once by JobDispatcher before dispatch.
     */
    public Map<String, Object> parameters { get; set; }

    /**
     * Shared mutable state across steps within the same pipeline run.
     * Loaded from JobPipelineRun__c.ContextData__c at dispatch time.
     * Jobs may write to this map; JobDispatcher persists changes back after
     * execution (handled by the wrappers in their finish logic).
     */
    public Map<String, Object> sharedContext { get; set; }

    /** 1-based attempt counter. 1 = first attempt, 2 = first retry, etc. */
    public Integer attemptNumber { get; set; }

    public JobExecutionContext() {
        parameters    = new Map<String, Object>();
        sharedContext = new Map<String, Object>();
        attemptNumber = 1;
    }

    /** Convenience getter — reads a typed parameter value or returns the provided default. */
    public Object getParameter(String key, Object defaultValue) {
        return parameters.containsKey(key) ? parameters.get(key) : defaultValue;
    }

    /** Convenience getter — reads a typed shared-context value or returns the provided default. */
    public Object getSharedValue(String key, Object defaultValue) {
        return sharedContext.containsKey(key) ? sharedContext.get(key) : defaultValue;
    }
}
