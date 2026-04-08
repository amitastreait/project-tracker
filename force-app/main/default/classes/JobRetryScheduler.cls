/**
 * JobRetryScheduler — Phase 4
 *
 * Schedulable fired by JobRetryHandler when RetryDelaySeconds__c > 0.
 * Waits for the configured delay, then re-dispatches the step with the
 * next attempt number via JobDispatcher.
 *
 * Guards against dispatching into a run that was cancelled or already closed
 * during the wait period.
 */
public without sharing class JobRetryScheduler implements Schedulable {

    @TestVisible private Id      pipelineRunId;
    @TestVisible private String  pipelineDeveloperName;
    @TestVisible private String  stepDeveloperName;
    @TestVisible private Integer attemptNumber;

    public JobRetryScheduler(
        Id      pipelineRunId,
        String  pipelineDeveloperName,
        String  stepDeveloperName,
        Integer attemptNumber
    ) {
        this.pipelineRunId         = pipelineRunId;
        this.pipelineDeveloperName = pipelineDeveloperName;
        this.stepDeveloperName     = stepDeveloperName;
        this.attemptNumber         = attemptNumber;
    }

    public void execute(SchedulableContext sc) {
        // Guard: do not re-dispatch if the pipeline run reached a terminal state
        // during the delay window (cancelled, completed, or failed by another path)
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

        // Load step CMT config — needed by JobDispatcher
        List<JobStep__mdt> steps = [
            SELECT DeveloperName, ApexClassName__c, ExecutionMode__c, BatchSize__c,
                   ExecutionOrder__c, IsActive__c, TimeoutMinutes__c,
                   ExecutionParameters__c, BranchGroup__c, RetryPolicy__c, Pipeline__c
            FROM   JobStep__mdt
            WHERE  DeveloperName             = :stepDeveloperName
            AND    Pipeline__r.DeveloperName = :pipelineDeveloperName
            LIMIT  1
        ];

        if (steps.isEmpty()) return;

        JobDispatcher.dispatch(steps[0], pipelineRunId, attemptNumber);
    }
}
