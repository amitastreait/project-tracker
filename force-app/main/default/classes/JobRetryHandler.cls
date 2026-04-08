/**
 * JobRetryHandler — Phase 4
 *
 * Called by job wrappers (JobQueueableWrapper, JobBatchWrapper) after a step fails.
 * Evaluates the step's JobRetryPolicy__mdt and either:
 *   • Retries  — marks the current execution Retrying, re-dispatches with attempt+1
 *   • Permanently fails — marks the execution Failed, publishes JobCompletionEvent__e
 *
 * Retry modes:
 *   RetryDelaySeconds__c = 0  → immediate via JobRetryDispatchQueueable (safe from Batch finish)
 *   RetryDelaySeconds__c > 0  → scheduled via JobRetryScheduler + publishes event so the
 *                               orchestrator sees the Retrying status and waits
 *
 * The 'Retrying' status on JobStepExecution__c is treated as non-terminal by the orchestrator,
 * so AbortPipeline does not fire and isPipelineComplete returns false while a retry is pending.
 */
public without sharing class JobRetryHandler {

    /**
     * Main entry point called by wrappers on step failure.
     *
     * @param ctx          Execution context populated by JobDispatcher
     * @param errorMessage The exception message or first batch error
     */
    public static void handleFailure(JobExecutionContext ctx, String errorMessage) {

        // Load the current execution to check attempt number
        JobStepExecution__c stepExec = [
            SELECT Id, AttemptNumber__c
            FROM   JobStepExecution__c
            WHERE  Id = :ctx.stepExecutionId
            LIMIT  1
        ];
        Integer currentAttempt = Integer.valueOf(stepExec.AttemptNumber__c);

        // Load the step CMT config — include retry policy fields via relationship traversal.
        // RetryPolicy__c is a MetadataRelationship (stores an internal ID, not a string),
        // so policy fields must be read through RetryPolicy__r, not by a second SOQL.
        List<JobStep__mdt> stepCfgs = [
            SELECT DeveloperName, ApexClassName__c, ExecutionMode__c, BatchSize__c,
                   ExecutionOrder__c, IsActive__c, TimeoutMinutes__c,
                   ExecutionParameters__c, BranchGroup__c, RetryPolicy__c, Pipeline__c,
                   RetryPolicy__r.MaxRetries__c,
                   RetryPolicy__r.RetryDelaySeconds__c,
                   RetryPolicy__r.RetryOnlyOnExceptions__c,
                   RetryPolicy__r.RetryExceptionTypes__c
            FROM   JobStep__mdt
            WHERE  DeveloperName             = :ctx.stepDeveloperName
            AND    Pipeline__r.DeveloperName = :ctx.pipelineDeveloperName
            LIMIT  1
        ];

        // No CMT found, or no retry policy linked on the step → permanent failure
        if (stepCfgs.isEmpty() || stepCfgs[0].RetryPolicy__r == null) {
            permanentFailure(stepExec, errorMessage, ctx);
            return;
        }

        JobStep__mdt       stepCfg = stepCfgs[0];
        Integer maxRetries   = stepCfg.RetryPolicy__r.MaxRetries__c        != null
                             ? Integer.valueOf(stepCfg.RetryPolicy__r.MaxRetries__c)        : 3;
        Integer delaySeconds = stepCfg.RetryPolicy__r.RetryDelaySeconds__c != null
                             ? Integer.valueOf(stepCfg.RetryPolicy__r.RetryDelaySeconds__c) : 0;

        if (currentAttempt >= maxRetries) {
            // All retries exhausted — permanent failure
            permanentFailure(stepExec,
                'Retry limit reached (' + maxRetries + ' attempts). Last error: ' + errorMessage,
                ctx);
            return;
        }

        // ── Retry ────────────────────────────────────────────────────────────────
        // Mark the current execution as Retrying (not Failed) so:
        //   • AbortPipeline policy does not trigger
        //   • isPipelineComplete returns false while the retry is pending
        stepExec.Status__c       = 'Retrying';
        stepExec.EndTime__c      = System.now();
        stepExec.ErrorMessage__c = errorMessage;
        update stepExec;

        Integer nextAttempt = currentAttempt + 1;

        if (delaySeconds > 0) {
            // Delayed retry — schedule a one-shot Schedulable
            DateTime runAt    = System.now().addSeconds(delaySeconds);
            String   jobName  = 'Retry_' + ctx.stepDeveloperName + '_Att' + nextAttempt
                              + '_' + System.now().getTime();
            System.schedule(
                jobName,
                buildCronExpression(runAt),
                new JobRetryScheduler(
                    ctx.pipelineRunId, ctx.pipelineDeveloperName,
                    ctx.stepDeveloperName, nextAttempt
                )
            );
            // Notify orchestrator so it can observe the Retrying status and wait
            publishEvent(ctx, false, errorMessage);

        } else {
            // Immediate retry — use a Queueable so Database.executeBatch can be called
            // from within a Batch finish() context without violating governor limits
            System.enqueueJob(
                new JobRetryDispatchQueueable(stepCfg, ctx.pipelineRunId, nextAttempt)
            );
            // No event needed here — the retry job's own completion event drives the orchestrator
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    private static void permanentFailure(
        JobStepExecution__c stepExec,
        String              errorMessage,
        JobExecutionContext  ctx
    ) {
        stepExec.Status__c       = 'Failed';
        stepExec.EndTime__c      = System.now();
        stepExec.ErrorMessage__c = errorMessage;
        update stepExec;
        publishEvent(ctx, false, errorMessage);
    }

    private static void publishEvent(JobExecutionContext ctx, Boolean isSuccess, String errorMessage) {
        EventBus.publish(new JobCompletionEvent__e(
            PipelineRunId__c     = String.valueOf(ctx.pipelineRunId),
            StepExecutionId__c   = String.valueOf(ctx.stepExecutionId),
            StepDeveloperName__c = ctx.stepDeveloperName,
            IsSuccess__c         = isSuccess,
            ErrorMessage__c      = errorMessage,
            RecordsProcessed__c  = 0
        ));
    }

    /**
     * Builds a Salesforce cron expression for a single one-shot fire at the given DateTime.
     * Format: Seconds Minutes Hours Day Month ? Year
     */
    @TestVisible
    private static String buildCronExpression(DateTime dt) {
        return String.valueOf(dt.second())  + ' '
             + String.valueOf(dt.minute())  + ' '
             + String.valueOf(dt.hour())    + ' '
             + String.valueOf(dt.day())     + ' '
             + String.valueOf(dt.month())   + ' ? '
             + String.valueOf(dt.year());
    }
}
