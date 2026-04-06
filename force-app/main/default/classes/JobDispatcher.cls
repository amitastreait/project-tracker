/**
 * JobDispatcher
 *
 * Handles the mechanics of turning a JobStep__mdt config record into a live
 * async Apex job. Called exclusively by JobOrchestrator.
 *
 * Responsibilities:
 *   1. Validate the Apex class exists and implements ISchedulableJob.
 *   2. Build a fully-populated JobExecutionContext (parameters + shared context).
 *   3. Insert a JobStepExecution__c record (Status = Running) before dispatching.
 *   4. Call System.enqueueJob or Database.executeBatch depending on ExecutionMode__c.
 *   5. Stamp the returned AsyncApexJob ID back onto the execution record.
 *
 * This class uses WITHOUT SHARING so the system-context Queueable can create
 * execution records regardless of the running user's object permissions.
 */
public without sharing class JobDispatcher {

    public class JobDispatchException extends Exception {}

    /**
     * Instantiates and dispatches the job defined by the given step config.
     *
     * @param step           The JobStep__mdt CMT record describing what to run.
     * @param pipelineRunId  The Id of the parent JobPipelineRun__c.
     * @param attemptNumber  1 for first attempt; incremented by JobRetryHandler on retries.
     * @return               The Id of the newly inserted JobStepExecution__c record.
     */
    public static Id dispatch(JobStep__mdt step, Id pipelineRunId, Integer attemptNumber) {
        // ── 1. Validate and instantiate the job class ────────────────────────
        Type jobType = Type.forName(step.ApexClassName__c);
        if (jobType == null) {
            throw new JobDispatchException(
                'Apex class not found: ' + step.ApexClassName__c +
                '. Verify the class exists and is deployed.'
            );
        }

        Object jobInstance = jobType.newInstance();
        if (!(jobInstance instanceof ISchedulableJob)) {
            throw new JobDispatchException(
                'Class ' + step.ApexClassName__c + ' does not implement ISchedulableJob.'
            );
        }

        ISchedulableJob job = (ISchedulableJob) jobInstance;

        // ── 2. Build execution context ───────────────────────────────────────
        JobExecutionContext ctx = buildContext(step, pipelineRunId, attemptNumber);

        // ── 3. Insert the step execution record before dispatch ──────────────
        //    We insert first so the ID exists before the async job starts.
        JobStepExecution__c stepExec = new JobStepExecution__c(
            PipelineRun__c        = pipelineRunId,
            StepDeveloperName__c  = step.DeveloperName,
            ApexClassName__c      = step.ApexClassName__c,
            Status__c             = 'Running',
            AttemptNumber__c      = attemptNumber,
            StartTime__c          = System.now()
        );
        insert stepExec;
        ctx.stepExecutionId = stepExec.Id;

        // ── 4. Dispatch ──────────────────────────────────────────────────────
        Id asyncJobId;
        if (step.ExecutionMode__c == 'Batch') {
            Integer batchSize = (step.BatchSize__c != null)
                ? Integer.valueOf(step.BatchSize__c)
                : 200;
            asyncJobId = Database.executeBatch(new JobBatchWrapper(job, ctx), batchSize);
        } else {
            asyncJobId = System.enqueueJob(new JobQueueableWrapper(job, ctx));
        }

        // ── 5. Stamp the async job ID ────────────────────────────────────────
        stepExec.AsyncApexJobId__c = String.valueOf(asyncJobId);
        update stepExec;

        return stepExec.Id;
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    private static JobExecutionContext buildContext(
        JobStep__mdt step,
        Id pipelineRunId,
        Integer attemptNumber
    ) {
        JobExecutionContext ctx = new JobExecutionContext();
        ctx.pipelineDeveloperName = step.Pipeline__c;
        ctx.stepDeveloperName     = step.DeveloperName;
        ctx.pipelineRunId         = pipelineRunId;
        ctx.attemptNumber         = attemptNumber;

        // Deserialize step-level parameters from CMT JSON blob
        if (String.isNotBlank(step.ExecutionParameters__c)) {
            ctx.parameters = (Map<String, Object>) JSON.deserializeUntyped(
                step.ExecutionParameters__c
            );
        }

        // Load shared context from the pipeline run record
        List<JobPipelineRun__c> runs = [
            SELECT ContextData__c
            FROM   JobPipelineRun__c
            WHERE  Id = :pipelineRunId
            LIMIT  1
        ];
        if (!runs.isEmpty() && String.isNotBlank(runs[0].ContextData__c)) {
            ctx.sharedContext = (Map<String, Object>) JSON.deserializeUntyped(
                runs[0].ContextData__c
            );
        }

        return ctx;
    }
}
