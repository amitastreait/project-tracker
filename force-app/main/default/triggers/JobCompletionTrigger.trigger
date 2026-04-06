/**
 * JobCompletionTrigger
 *
 * Fires on every JobCompletionEvent__e Platform Event publication.
 * Re-enters the JobOrchestrator for the pipeline run that just had a
 * step complete, allowing it to evaluate dependencies and dispatch the
 * next ready step(s).
 *
 * Because Platform Events are processed in a fresh, top-level transaction,
 * the Queueable chain-depth counter resets to 0 here — this is what lets
 * the engine execute a pipeline of arbitrary length without hitting the
 * 50-deep Queueable limit.
 *
 * One enqueueJob call per unique PipelineRunId__c in the event batch;
 * duplicates within the same batch are deduplicated to avoid redundant
 * orchestrator invocations.
 */
trigger JobCompletionTrigger on JobCompletionEvent__e (after insert) {
    Set<Id> runIds = new Set<Id>();

    for (JobCompletionEvent__e evt : Trigger.new) {
        if (String.isNotBlank(evt.PipelineRunId__c)) {
            try {
                runIds.add((Id) evt.PipelineRunId__c);
            } catch (Exception ex) {
                // Malformed ID — skip silently; orchestrator will eventually timeout
            }
        }
    }

    for (Id runId : runIds) {
        System.enqueueJob(new JobOrchestrator(runId));
    }
}
