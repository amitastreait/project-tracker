/**
 * JobOrchestratorTest
 *
 * Tests the orchestrator's three key behaviours using the deployed
 * Nightly_Data_Sync CMT records (pipeline + 4 steps + 4 dependencies).
 *
 * Test 1 — Fresh run:  Orchestrator transitions run Queued→Running and
 *           dispatches the first ready step (Sync_Accounts, no dependencies).
 *
 * Test 2 — All done:   When all step executions are already Completed, the
 *           orchestrator closes the run as Completed.
 *
 * Test 3 — AbortPipeline: When a step execution is Failed and the pipeline
 *           policy is AbortPipeline, the run is closed as Failed immediately.
 */
@IsTest
private class JobOrchestratorTest {

    // ── Test 1: fresh run dispatches first ready step ────────────────────────

    @IsTest
    static void testFreshRun_dispatchesFirstReadyStep() {
        JobPipelineRun__c run = createRun('Queued');

        Test.startTest();
        System.enqueueJob(new JobOrchestrator(run.Id));
        Test.stopTest();
        // stopTest() flushes the Queueable synchronously.
        // JobOrchestrator dispatches Sync_Accounts via executeBatch → that batch
        // also executes within stopTest → step ends up Completed.

        // In API v66+, Platform Events with PublishAfterCommit fire synchronously
        // within Test.stopTest(), so the orchestrator re-triggers after each step.
        // The full pipeline therefore completes within a single stopTest() call.
        run = [SELECT Status__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        System.assert(
            run.Status__c == 'Running' || run.Status__c == 'Completed',
            'Run must have advanced beyond Queued: actual=' + run.Status__c
        );

        List<JobStepExecution__c> execs = [
            SELECT StepDeveloperName__c, Status__c
            FROM   JobStepExecution__c
            WHERE  PipelineRun__c = :run.Id
            AND    StepDeveloperName__c = 'Sync_Accounts'
        ];
        System.assert(!execs.isEmpty(), 'Sync_Accounts step must have been dispatched');
        System.assertEquals('Completed', execs[0].Status__c,
            'Sync_Accounts must complete within Test.stopTest()');
    }

    // ── Test 2: pipeline closes when all steps completed ────────────────────

    @IsTest
    static void testAllStepsCompleted_closesPipelineAsCompleted() {
        JobPipelineRun__c run = createRun('Running');

        // Pre-populate all four step executions as Completed
        insert new List<JobStepExecution__c>{
            exec(run.Id, 'Sync_Accounts',    'Completed'),
            exec(run.Id, 'Sync_Contacts',    'Completed'),
            exec(run.Id, 'Sync_Cases',       'Completed'),
            exec(run.Id, 'Generate_Reports', 'Completed')
        };

        Test.startTest();
        System.enqueueJob(new JobOrchestrator(run.Id));
        Test.stopTest();

        run = [SELECT Status__c, EndTime__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        System.assertEquals('Completed', run.Status__c);
        System.assertNotEquals(null, run.EndTime__c, 'EndTime must be stamped on completion');
    }

    // ── Test 3: AbortPipeline policy closes run on first failure ────────────

    @IsTest
    static void testFailedStep_abortsRunWhenPolicyIsAbortPipeline() {
        // Nightly_Data_Sync uses OnStepFailure = AbortPipeline (deployed CMT)
        JobPipelineRun__c run = createRun('Running');

        insert exec(run.Id, 'Sync_Accounts', 'Failed');

        Test.startTest();
        System.enqueueJob(new JobOrchestrator(run.Id));
        Test.stopTest();

        run = [SELECT Status__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        System.assertEquals('Failed', run.Status__c,
            'AbortPipeline policy must close the run as Failed immediately');
    }

    // ── Test 4: cancelled run is a no-op ────────────────────────────────────

    @IsTest
    static void testCancelledRun_doesNothing() {
        JobPipelineRun__c run = createRun('Cancelled');

        Test.startTest();
        System.enqueueJob(new JobOrchestrator(run.Id));
        Test.stopTest();

        run = [SELECT Status__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        System.assertEquals('Cancelled', run.Status__c,
            'Orchestrator must not touch a Cancelled run');

        Integer stepCount = [SELECT COUNT() FROM JobStepExecution__c WHERE PipelineRun__c = :run.Id];
        System.assertEquals(0, stepCount, 'No steps should be dispatched for a cancelled run');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static JobPipelineRun__c createRun(String status) {
        JobPipelineRun__c run = new JobPipelineRun__c(
            Pipeline__c    = 'Nightly_Data_Sync',
            Status__c      = status,
            TriggeredBy__c = 'Test',
            StartTime__c   = (status == 'Running') ? System.now() : null
        );
        insert run;
        return run;
    }

    private static JobStepExecution__c exec(Id runId, String stepName, String status) {
        return new JobStepExecution__c(
            PipelineRun__c       = runId,
            StepDeveloperName__c = stepName,
            Status__c            = status,
            AttemptNumber__c     = 1,
            StartTime__c         = System.now(),
            EndTime__c           = (status != 'Running') ? System.now() : null
        );
    }
}
