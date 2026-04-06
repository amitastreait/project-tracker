/**
 * SyncContactsJobTest
 *
 * Verifies SyncContactsJob reads accountsSyncedToday from sharedContext and
 * writes contactsSyncedToday + contactToAccountRatio after the batch completes.
 */
@IsTest
private class SyncContactsJobTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;
        insert new Contact(LastName = 'Test Contact', AccountId = acc.Id);
    }

    @IsTest
    static void testBatchProcessesContactsAndWritesSharedContext() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        JobPipelineRun__c run = run(JSON.serialize(
            new Map<String, Object>{ 'accountsSyncedToday' => 1 }
        ));
        JobStepExecution__c exec = exec(run.Id, 'Sync_Contacts');
        JobExecutionContext ctx  = ctx(run.Id, exec.Id, 'Sync_Contacts');
        // Pre-load the sharedContext so the job can read it
        ctx.sharedContext.put('accountsSyncedToday', 1);

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncContactsJob(), ctx), 200);
        Test.stopTest();

        exec = [SELECT Status__c, RecordsProcessed__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c);
        System.assertEquals(1, exec.RecordsProcessed__c);

        run = [SELECT ContextData__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        Map<String, Object> shared = (Map<String, Object>) JSON.deserializeUntyped(run.ContextData__c);
        System.assert(shared.containsKey('contactsSyncedToday'),   'contactsSyncedToday must be set');
        System.assert(shared.containsKey('contactToAccountRatio'), 'contactToAccountRatio must be set');
    }

    @IsTest
    static void testRatioIsZeroWhenNoAccounts() {
        // accountsSyncedToday = 0 — ratio should be 0, not division error
        JobPipelineRun__c run = run(null);
        JobStepExecution__c exec = exec(run.Id, 'Sync_Contacts');
        JobExecutionContext ctx  = ctx(run.Id, exec.Id, 'Sync_Contacts');
        ctx.sharedContext.put('accountsSyncedToday', 0);

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncContactsJob(), ctx), 200);
        Test.stopTest();

        run = [SELECT ContextData__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        Map<String, Object> shared = (Map<String, Object>) JSON.deserializeUntyped(run.ContextData__c);
        System.assertEquals(0, shared.get('contactToAccountRatio'), 'Ratio must be 0 when no accounts');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static JobPipelineRun__c run(String contextData) {
        JobPipelineRun__c r = new JobPipelineRun__c(
            Pipeline__c    = 'Nightly_Data_Sync',
            Status__c      = 'Running',
            StartTime__c   = System.now(),
            ContextData__c = contextData
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
