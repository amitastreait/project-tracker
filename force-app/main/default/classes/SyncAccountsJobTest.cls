/**
 * SyncAccountsJobTest
 *
 * Runs SyncAccountsJob through JobBatchWrapper end-to-end.
 * Verifies:
 *   - Step execution is marked Completed with correct record counts.
 *   - sharedContext is persisted back to JobPipelineRun__c.ContextData__c.
 *   - accountsSyncedToday is written into sharedContext.
 */
@IsTest
private class SyncAccountsJobTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Test Account A');
    }

    @IsTest
    static void testBatchProcessesAccountsAndCompletesStep() {
        JobPipelineRun__c run = run();
        JobStepExecution__c exec = exec(run.Id, 'Sync_Accounts');
        JobExecutionContext ctx = ctx(run.Id, exec.Id, 'Sync_Accounts');

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncAccountsJob(), ctx), 200);
        Test.stopTest();

        exec = [SELECT Status__c, RecordsProcessed__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c);
        System.assertEquals(1, exec.RecordsProcessed__c, 'One account must be counted');

        // Verify sharedContext was written back to the run
        run = [SELECT ContextData__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        System.assertNotEquals(null, run.ContextData__c, 'ContextData must be populated');
        Map<String, Object> shared = (Map<String, Object>) JSON.deserializeUntyped(run.ContextData__c);
        System.assert(shared.containsKey('accountsSyncedToday'), 'accountsSyncedToday must be present');
    }

    @IsTest
    static void testBatchWithNoMatchingAccounts_stillCompletes() {
        // Use a lookback of 0 hours — nothing will match
        JobPipelineRun__c run = run();
        JobStepExecution__c exec = exec(run.Id, 'Sync_Accounts');
        JobExecutionContext ctx = ctx(run.Id, exec.Id, 'Sync_Accounts');
        ctx.parameters.put('lookbackHours', 0); // Nothing modified in the future

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncAccountsJob(), ctx), 200);
        Test.stopTest();

        exec = [SELECT Status__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c,
            'Batch with 0 records must still complete cleanly');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static JobPipelineRun__c run() {
        JobPipelineRun__c r = new JobPipelineRun__c(
            Pipeline__c = 'Nightly_Data_Sync', Status__c = 'Running', StartTime__c = System.now()
        );
        insert r;
        return r;
    }

    private static JobStepExecution__c exec(Id runId, String stepName) {
        JobStepExecution__c e = new JobStepExecution__c(
            PipelineRun__c = runId, StepDeveloperName__c = stepName,
            Status__c = 'Running', AttemptNumber__c = 1, StartTime__c = System.now()
        );
        insert e;
        return e;
    }

    private static JobExecutionContext ctx(Id runId, Id execId, String stepName) {
        JobExecutionContext c = new JobExecutionContext();
        c.pipelineRunId       = runId;
        c.stepExecutionId     = execId;
        c.stepDeveloperName   = stepName;
        c.pipelineDeveloperName = 'Nightly_Data_Sync';
        return c;
    }
}
