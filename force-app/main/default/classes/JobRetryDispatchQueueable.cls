/**
 * JobRetryDispatchQueueable — Phase 4
 *
 * Thin Queueable used by JobRetryHandler for zero-delay retries.
 *
 * Why a separate Queueable?
 * JobBatchWrapper.finish() is a Batch context. Calling Database.executeBatch()
 * directly from within a Batch finish() throws a governor exception.
 * Enqueuing this Queueable instead moves the dispatch into a fresh transaction
 * where executeBatch (and enqueueJob) are both legal.
 *
 * For Queueable-mode steps the dispatch could also be done inline, but using
 * this wrapper keeps the retry path consistent regardless of execution mode.
 */
public without sharing class JobRetryDispatchQueueable implements Queueable {

    private JobStep__mdt stepCfg;
    private Id           pipelineRunId;
    private Integer      attemptNumber;

    public JobRetryDispatchQueueable(
        JobStep__mdt stepCfg,
        Id           pipelineRunId,
        Integer      attemptNumber
    ) {
        this.stepCfg       = stepCfg;
        this.pipelineRunId = pipelineRunId;
        this.attemptNumber = attemptNumber;
    }

    public void execute(QueueableContext qc) {
        // Guard: skip if the pipeline run reached a terminal state
        List<JobPipelineRun__c> runs = [
            SELECT Status__c
            FROM   JobPipelineRun__c
            WHERE  Id = :pipelineRunId
            LIMIT  1
        ];
        if (runs.isEmpty()
            || runs[0].Status__c == 'Completed'
            || runs[0].Status__c == 'Failed'
            || runs[0].Status__c == 'Cancelled') {
            return;
        }

        JobDispatcher.dispatch(stepCfg, pipelineRunId, attemptNumber);
    }
}
