/**
 * SyncCasesJobTest
 *
 * Verifies SyncCasesJob processes cases and writes caseCountsByStatus
 * into sharedContext. Also tests the optional status-filter parameter.
 */
@IsTest
private class SyncCasesJobTest {

    @TestSetup
    static void setup() {
        insert new List<Case>{
            new Case(Subject = 'Case 1', Status = 'New'),
            new Case(Subject = 'Case 2', Status = 'New'),
            new Case(Subject = 'Case 3', Status = 'Closed')
        };
    }

    @IsTest
    static void testBatchProcessesAllCasesAndWritesCounts() {
        JobPipelineRun__c run   = run();
        JobStepExecution__c exec = exec(run.Id);
        JobExecutionContext ctx  = ctx(run.Id, exec.Id);

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncCasesJob(), ctx), 200);
        Test.stopTest();

        exec = [SELECT Status__c, RecordsProcessed__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c);
        System.assertEquals(3, exec.RecordsProcessed__c, '3 cases must be processed');

        run = [SELECT ContextData__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        Map<String, Object> shared = (Map<String, Object>) JSON.deserializeUntyped(run.ContextData__c);
        System.assert(shared.containsKey('caseCountsByStatus'), 'caseCountsByStatus must be written');
    }

    @IsTest
    static void testBatchWithStatusFilter_processesOnlyMatchingCases() {
        JobPipelineRun__c run   = run();
        JobStepExecution__c exec = exec(run.Id);
        JobExecutionContext ctx  = ctx(run.Id, exec.Id);
        ctx.parameters.put('caseStatus', 'New'); // Only process New cases (2 of 3)

        Test.startTest();
        Database.executeBatch(new JobBatchWrapper(new SyncCasesJob(), ctx), 200);
        Test.stopTest();

        exec = [SELECT Status__c, RecordsProcessed__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c);
        System.assertEquals(2, exec.RecordsProcessed__c, 'Only 2 New cases must match the filter');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static JobPipelineRun__c run() {
        JobPipelineRun__c r = new JobPipelineRun__c(
            Pipeline__c = 'Nightly_Data_Sync', Status__c = 'Running', StartTime__c = System.now()
        );
        insert r;
        return r;
    }

    private static JobStepExecution__c exec(Id runId) {
        JobStepExecution__c e = new JobStepExecution__c(
            PipelineRun__c = runId, StepDeveloperName__c = 'Sync_Cases',
            Status__c = 'Running', AttemptNumber__c = 1, StartTime__c = System.now()
        );
        insert e;
        return e;
    }

    private static JobExecutionContext ctx(Id runId, Id execId) {
        JobExecutionContext c = new JobExecutionContext();
        c.pipelineRunId       = runId;
        c.stepExecutionId     = execId;
        c.stepDeveloperName   = 'Sync_Cases';
        c.pipelineDeveloperName = 'Nightly_Data_Sync';
        return c;
    }
}
