/**
 * JobQueueableWrapper
 *
 * Wraps any ISchedulableJob implementation for Queueable execution.
 * The framework owns the full lifecycle; the job class just implements execute().
 *
 * Responsibilities:
 *   • Call ISchedulableJob.execute(ctx) within a try-catch.
 *   • Update JobStepExecution__c with terminal status, timing, and error details.
 *   • Persist any changes to sharedContext back to JobPipelineRun__c.ContextData__c.
 *   • Publish JobCompletionEvent__e to re-trigger JobOrchestrator via Platform Event.
 *
 * On failure: delegates to JobRetryHandler which decides whether to retry (Retrying status)
 * or permanently fail (Failed status + publishes JobCompletionEvent__e).
 */
public without sharing class JobQueueableWrapper implements Queueable {

    private ISchedulableJob job;
    private JobExecutionContext ctx;

    public JobQueueableWrapper(ISchedulableJob job, JobExecutionContext ctx) {
        this.job = job;
        this.ctx = ctx;
    }

    public void execute(QueueableContext qc) {
        JobStepExecution__c stepExec = [
            SELECT Id, Status__c, RecordsFailed__c
            FROM   JobStepExecution__c
            WHERE  Id = :ctx.stepExecutionId
            LIMIT  1
        ];

        try {
            job.execute(ctx);

            stepExec.Status__c  = 'Completed';
            stepExec.EndTime__c = System.now();
            update stepExec;

            persistSharedContext();
            publishEvent(true, null, 0);

        } catch (Exception ex) {
            // Store the stack trace (RetryHandler owns Status, EndTime, ErrorMessage)
            stepExec.ErrorStackTrace__c = ex.getStackTraceString();
            update stepExec;

            // Persist any partial sharedContext written before the exception
            persistSharedContext();

            // Delegate to retry handler — retries if policy allows, otherwise marks Failed
            JobRetryHandler.handleFailure(ctx, ex.getMessage());
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    private void persistSharedContext() {
        if (ctx.sharedContext == null || ctx.sharedContext.isEmpty()) return;
        update new JobPipelineRun__c(
            Id          = ctx.pipelineRunId,
            ContextData__c = JSON.serialize(ctx.sharedContext)
        );
    }

    private void publishEvent(Boolean isSuccess, String errorMsg, Integer recordsProcessed) {
        EventBus.publish(new JobCompletionEvent__e(
            PipelineRunId__c      = String.valueOf(ctx.pipelineRunId),
            StepExecutionId__c    = String.valueOf(ctx.stepExecutionId),
            StepDeveloperName__c  = ctx.stepDeveloperName,
            IsSuccess__c          = isSuccess,
            ErrorMessage__c       = errorMsg,
            RecordsProcessed__c   = recordsProcessed
        ));
    }
}
