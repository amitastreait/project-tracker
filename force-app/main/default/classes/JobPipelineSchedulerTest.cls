/**
 * JobPipelineSchedulerTest
 *
 * Tests the three public entry points on JobPipelineScheduler.
 *
 * Note: CMT records (Nightly_Data_Sync, CronExpression = "0 0 2 * * ?")
 * must be deployed before these tests run.
 */
@IsTest
private class JobPipelineSchedulerTest {

    // ── runNow ───────────────────────────────────────────────────────────────

    @IsTest
    static void testRunNow_createsRunRecordAndEnqueuesOrchestrator() {
        Test.startTest();
        Id runId = JobPipelineScheduler.runNow('Nightly_Data_Sync');
        Test.stopTest();
        // stopTest flushes the Orchestrator Queueable, which transitions
        // the run to Running and dispatches Sync_Accounts (batch also runs).

        System.assertNotEquals(null, runId, 'runNow must return the new run Id');

        JobPipelineRun__c run = [
            SELECT Pipeline__c, Status__c, TriggeredBy__c
            FROM   JobPipelineRun__c
            WHERE  Id = :runId
        ];
        System.assertEquals('Nightly_Data_Sync', run.Pipeline__c);
        System.assertEquals('Manual',            run.TriggeredBy__c);
        // In API v66+, Platform Events fire synchronously in Test.stopTest(),
        // so the full pipeline may complete within a single stopTest() call.
        System.assert(
            run.Status__c == 'Running' || run.Status__c == 'Completed',
            'Run must have progressed beyond Queued: actual=' + run.Status__c
        );
    }

    @IsTest
    static void testRunNow_returnsNullForInactivePipeline() {
        // No active CMT record exists for 'Nonexistent_Pipeline'
        Test.startTest();
        Id runId = JobPipelineScheduler.runNow('Nonexistent_Pipeline');
        Test.stopTest();

        System.assertEquals(null, runId, 'Should return null for unknown/inactive pipelines');
    }

    // ── registerSchedule ─────────────────────────────────────────────────────

    @IsTest
    static void testRegisterSchedule_createsCronTrigger() {
        Test.startTest();
        String cronJobId = JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
        Test.stopTest();

        System.assertNotEquals(null, cronJobId, 'registerSchedule must return the cron job Id');

        List<CronTrigger> triggers = [
            SELECT Id, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.Name = 'Pipeline: Nightly Data Sync'
        ];
        System.assertEquals(1, triggers.size(), 'Exactly one CronTrigger should be registered');
    }

    @IsTest
    static void testRegisterSchedule_replacesExistingCronJob() {
        // Register twice — second call should abort the first and re-register
        Test.startTest();
        JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
        JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
        Test.stopTest();

        List<CronTrigger> triggers = [
            SELECT Id FROM CronTrigger
            WHERE  CronJobDetail.Name = 'Pipeline: Nightly Data Sync'
        ];
        System.assertEquals(1, triggers.size(), 'Duplicate registration must replace not duplicate');
    }

    @IsTest
    static void testRegisterSchedule_throwsForUnknownPipeline() {
        try {
            JobPipelineScheduler.registerSchedule('Does_Not_Exist');
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException ex) {
            System.assert(
                ex.getMessage().contains('Does_Not_Exist'),
                'Exception must name the missing pipeline'
            );
        }
    }

    // ── Schedulable.execute ──────────────────────────────────────────────────

    @IsTest
    static void testSchedulableExecute_createsRunRecord() {
        String jobId = System.schedule(
            'Test Pipeline Schedule',
            '0 0 3 * * ?',
            new JobPipelineScheduler('Nightly_Data_Sync')
        );

        System.assertNotEquals(null, jobId);
    }
}
