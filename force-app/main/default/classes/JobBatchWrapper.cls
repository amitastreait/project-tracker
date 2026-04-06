/**
 * JobBatchWrapper
 *
 * Wraps any ISchedulableJob implementation for Batch Apex execution.
 * Delegates all three batch lifecycle methods to the underlying job class,
 * then publishes JobCompletionEvent__e in finish() to re-trigger the orchestrator.
 *
 * Record counting:
 *   Jobs should update JobStepExecution__c.RecordsProcessed__c /
 *   JobStepExecution__c.RecordsFailed__c directly (via the Id in ctx.stepExecutionId)
 *   from within executeBatch() if they want accurate counts.
 *   Alternatively they can update ctx.sharedContext and this wrapper will persist it.
 *
 * Note: retry logic will be wired in during Phase 4 (JobRetryHandler).
 */
public without sharing class JobBatchWrapper implements Database.Batchable<SObject>, Database.Stateful {

    private ISchedulableJob job;
    private JobExecutionContext ctx;

    // Accumulators updated by the job in executeBatch() via direct field updates,
    // or tracked here as a fallback.
    private Integer totalProcessed = 0;
    private Integer totalFailed    = 0;
    private String  firstError     = null;

    public JobBatchWrapper(ISchedulableJob job, JobExecutionContext ctx) {
        this.job = job;
        this.ctx = ctx;
    }

    // ── Batch lifecycle ─────────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return job.getQueryLocator(ctx);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        try {
            job.executeBatch(ctx, scope);
            totalProcessed += scope.size();
        } catch (Exception ex) {
            totalFailed += scope.size();
            if (firstError == null) {
                firstError = ex.getMessage();
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Delegate any post-processing to the job implementation
        try {
            job.finishBatch(ctx);
        } catch (Exception ex) {
            if (firstError == null) {
                firstError = ex.getMessage();
            }
        }

        // ── Update the step execution record ─────────────────────────────────
        JobStepExecution__c stepExec = [
            SELECT Id, Status__c, RecordsProcessed__c, RecordsFailed__c
            FROM   JobStepExecution__c
            WHERE  Id = :ctx.stepExecutionId
            LIMIT  1
        ];

        Boolean isSuccess = (firstError == null);
        stepExec.Status__c          = isSuccess ? 'Completed' : 'Failed';
        stepExec.EndTime__c         = System.now();
        stepExec.ErrorMessage__c    = firstError;

        // If the job updated counts directly on the record, those will be in
        // stepExec already. If not, stamp the wrapper's accumulators.
        if (stepExec.RecordsProcessed__c == null) {
            stepExec.RecordsProcessed__c = totalProcessed;
        }
        if (stepExec.RecordsFailed__c == null) {
            stepExec.RecordsFailed__c = totalFailed;
        }
        update stepExec;

        // Persist shared context changes from finishBatch()
        if (ctx.sharedContext != null && !ctx.sharedContext.isEmpty()) {
            update new JobPipelineRun__c(
                Id             = ctx.pipelineRunId,
                ContextData__c = JSON.serialize(ctx.sharedContext)
            );
        }

        // ── Publish completion event to advance the pipeline ─────────────────
        EventBus.publish(new JobCompletionEvent__e(
            PipelineRunId__c     = String.valueOf(ctx.pipelineRunId),
            StepExecutionId__c   = String.valueOf(ctx.stepExecutionId),
            StepDeveloperName__c = ctx.stepDeveloperName,
            IsSuccess__c         = isSuccess,
            ErrorMessage__c      = firstError,
            RecordsProcessed__c  = totalProcessed
        ));
    }
}
