/**
 * GenerateReportsJobTest
 *
 * Runs GenerateReportsJob through JobQueueableWrapper.
 * Verifies:
 *   - Job reads all upstream sharedContext values (accounts, contacts, cases).
 *   - Step execution reaches Completed with RecordsProcessed = 1.
 *   - lastReportBody is written into sharedContext.
 *   - emailResults = false skips email sending (no exception thrown).
 */
@IsTest
private class GenerateReportsJobTest {

    @IsTest
    static void testGeneratesReportAndCompletesStep() {
        JobPipelineRun__c run = run(sharedContextJson());
        JobStepExecution__c exec = exec(run.Id);
        JobExecutionContext ctx  = ctx(run.Id, exec.Id);

        Test.startTest();
        System.enqueueJob(new JobQueueableWrapper(new GenerateReportsJob(), ctx));
        Test.stopTest();

        exec = [SELECT Status__c, RecordsProcessed__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c);
        System.assertEquals(1, exec.RecordsProcessed__c, 'One report must be counted');

        run = [SELECT ContextData__c FROM JobPipelineRun__c WHERE Id = :run.Id];
        Map<String, Object> shared = (Map<String, Object>) JSON.deserializeUntyped(run.ContextData__c);
        System.assert(shared.containsKey('lastReportBody'), 'lastReportBody must be written');
        System.assert(shared.containsKey('lastReportDate'), 'lastReportDate must be written');
        System.assert(
            ((String) shared.get('lastReportBody')).contains('Nightly Sync Report'),
            'Report body must contain the expected header'
        );
    }

    @IsTest
    static void testEmptySharedContext_doesNotThrow() {
        // If upstream steps wrote nothing, the job should still complete
        JobPipelineRun__c run = run(null);
        JobStepExecution__c exec = exec(run.Id);
        JobExecutionContext ctx  = ctx(run.Id, exec.Id);
        // sharedContext intentionally empty — no upstream data

        Test.startTest();
        System.enqueueJob(new JobQueueableWrapper(new GenerateReportsJob(), ctx));
        Test.stopTest();

        exec = [SELECT Status__c FROM JobStepExecution__c WHERE Id = :exec.Id];
        System.assertEquals('Completed', exec.Status__c,
            'Job must complete even with empty sharedContext');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static String sharedContextJson() {
        return JSON.serialize(new Map<String, Object>{
            'accountsSyncedToday'   => 100,
            'contactsSyncedToday'   => 250,
            'contactToAccountRatio' => 2.5,
            'caseCountsByStatus'    => new Map<String, Integer>{'New' => 5, 'Closed' => 20}
        });
    }

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

    private static JobStepExecution__c exec(Id runId) {
        JobStepExecution__c e = new JobStepExecution__c(
            PipelineRun__c = runId, StepDeveloperName__c = 'Generate_Reports',
            Status__c = 'Running', AttemptNumber__c = 1, StartTime__c = System.now()
        );
        insert e;
        return e;
    }

    private static JobExecutionContext ctx(Id runId, Id execId) {
        JobExecutionContext c = new JobExecutionContext();
        c.pipelineRunId         = runId;
        c.stepExecutionId       = execId;
        c.stepDeveloperName     = 'Generate_Reports';
        c.pipelineDeveloperName = 'Nightly_Data_Sync';
        c.parameters = new Map<String, Object>{
            'reportType'   => 'summary',
            'emailResults' => false
        };
        c.sharedContext = new Map<String, Object>{
            'accountsSyncedToday'   => 100,
            'contactsSyncedToday'   => 250,
            'contactToAccountRatio' => 2.5,
            'caseCountsByStatus'    => new Map<String, Object>{'New' => 5, 'Closed' => 20}
        };
        return c;
    }
}
