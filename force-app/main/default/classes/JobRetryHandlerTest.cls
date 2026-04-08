/**
 * JobRetryHandlerTest
 *
 * Tests JobRetryHandler's three decision paths:
 *   1. No retry policy (or step CMT not found) → permanent failure immediately
 *   2. Retry policy present, attempts remaining → status = Retrying, retry scheduled
 *   3. Retry policy present, attempts exhausted → permanent failure
 *   4. buildCronExpression helper produces correct Salesforce cron string
 *
 * Uses deployed CMT records:
 *   • Sync_Accounts (Pipeline: Nightly_Data_Sync, RetryPolicy: Standard_Retry)
 *   • Standard_Retry (MaxRetries: 3, RetryDelaySeconds: 60)
 */
@IsTest
private class JobRetryHandlerTest {

    // ── Test 1: no retry policy ──────────────────────────────────────────────

    @IsTest
    static void testPermanentFailure_stepCmtNotFound() {
        // A step developer name that matches no deployed CMT → handler falls through
        // to the "no policy found" branch and marks the execution Failed immediately.
        JobPipelineRun__c run  = createRun();
        JobStepExecution__c ex = createExec(run.Id, 'NonExistent_Step', 1);

        Test.startTest();
        JobRetryHandler.handleFailure(
            makeCtx(run.Id, 'Nightly_Data_Sync', 'NonExistent_Step', ex.Id, 1),
            'Simulated error'
        );
        Test.stopTest();

        ex = [SELECT Status__c, ErrorMessage__c FROM JobStepExecution__c WHERE Id = :ex.Id];
        System.assertEquals('Failed', ex.Status__c, 'Step must be permanently Failed when no CMT found');
        System.assert(ex.ErrorMessage__c.contains('Simulated error'),
            'ErrorMessage must contain the original error');
    }

    // ── Test 2: retry policy present, attempts remaining ────────────────────

    @IsTest
    static void testRetry_attemptsRemaining_setsRetryingAndSchedules() {
        // Sync_Accounts has Standard_Retry (MaxRetries=3, RetryDelaySeconds=60).
        // Attempt 1 < 3 → handler should set Retrying and create a scheduled job.
        JobPipelineRun__c   run = createRun();
        JobStepExecution__c ex  = createExec(run.Id, 'Sync_Accounts', 1);

        Test.startTest();
        JobRetryHandler.handleFailure(
            makeCtx(run.Id, 'Nightly_Data_Sync', 'Sync_Accounts', ex.Id, 1),
            'Connection timeout'
        );
        Test.stopTest();

        ex = [SELECT Status__c, ErrorMessage__c FROM JobStepExecution__c WHERE Id = :ex.Id];
        System.assertEquals('Retrying', ex.Status__c,
            'Step must be in Retrying state when attempts remain');
        System.assertEquals('Connection timeout', ex.ErrorMessage__c,
            'ErrorMessage must be preserved for audit');

        // A one-shot scheduled retry job must have been created
        List<CronTrigger> jobs = [
            SELECT Id, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.Name LIKE 'Retry_Sync_Accounts_%'
        ];
        System.assertEquals(1, jobs.size(), 'Exactly one retry CronTrigger must be created');
    }

    @IsTest
    static void testRetry_secondAttemptAlsoRetries() {
        // Attempt 2 < 3 → still retries
        JobPipelineRun__c   run = createRun();
        JobStepExecution__c ex  = createExec(run.Id, 'Sync_Accounts', 2);

        Test.startTest();
        JobRetryHandler.handleFailure(
            makeCtx(run.Id, 'Nightly_Data_Sync', 'Sync_Accounts', ex.Id, 2),
            'Timeout again'
        );
        Test.stopTest();

        ex = [SELECT Status__c FROM JobStepExecution__c WHERE Id = :ex.Id];
        System.assertEquals('Retrying', ex.Status__c, 'Attempt 2 of 3 should still retry');
    }

    // ── Test 3: retry policy present, attempts exhausted ────────────────────

    @IsTest
    static void testPermanentFailure_retriesExhausted() {
        // Attempt 3 = MaxRetries → no more retries, must permanently fail.
        JobPipelineRun__c   run = createRun();
        JobStepExecution__c ex  = createExec(run.Id, 'Sync_Accounts', 3);

        Test.startTest();
        JobRetryHandler.handleFailure(
            makeCtx(run.Id, 'Nightly_Data_Sync', 'Sync_Accounts', ex.Id, 3),
            'Final failure'
        );
        Test.stopTest();

        ex = [SELECT Status__c, ErrorMessage__c FROM JobStepExecution__c WHERE Id = :ex.Id];
        System.assertEquals('Failed', ex.Status__c,
            'Step must be permanently Failed after exhausting retries');
        System.assert(ex.ErrorMessage__c.contains('Retry limit reached'),
            'ErrorMessage must indicate retry limit was reached');
        System.assert(ex.ErrorMessage__c.contains('3'),
            'ErrorMessage must state the max retry count');

        // No retry schedule should have been created
        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Retry_Sync_Accounts_%'
        ];
        System.assertEquals(0, jobs.size(), 'No CronTrigger should be created when retries are exhausted');
    }

    // ── Test 4: cron expression builder ──────────────────────────────────────

    @IsTest
    static void testBuildCronExpression() {
        DateTime dt = DateTime.newInstance(2026, 6, 15, 14, 30, 45);
        String   cron = JobRetryHandler.buildCronExpression(dt);
        System.assertEquals('45 30 14 15 6 ? 2026', cron,
            'Cron expression must be in Salesforce format: S M H D Mon ? Y');
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    private static JobPipelineRun__c createRun() {
        JobPipelineRun__c run = new JobPipelineRun__c(
            Pipeline__c    = 'Nightly_Data_Sync',
            Status__c      = 'Running',
            TriggeredBy__c = 'Manual',
            StartTime__c   = System.now()
        );
        insert run;
        return run;
    }

    private static JobStepExecution__c createExec(Id runId, String stepName, Integer attempt) {
        JobStepExecution__c ex = new JobStepExecution__c(
            PipelineRun__c       = runId,
            StepDeveloperName__c = stepName,
            Status__c            = 'Running',
            AttemptNumber__c     = attempt,
            StartTime__c         = System.now()
        );
        insert ex;
        return ex;
    }

    private static JobExecutionContext makeCtx(
        Id runId, String pipeline, String step, Id execId, Integer attempt
    ) {
        JobExecutionContext ctx = new JobExecutionContext();
        ctx.pipelineRunId         = runId;
        ctx.pipelineDeveloperName = pipeline;
        ctx.stepDeveloperName     = step;
        ctx.stepExecutionId       = execId;
        ctx.attemptNumber         = attempt;
        return ctx;
    }
}
