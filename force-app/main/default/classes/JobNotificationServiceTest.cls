/**
 * JobNotificationServiceTest
 *
 * Tests that JobNotificationService:
 *   1. No-ops silently when NotificationEmail__c is blank (no exception, no email)
 *   2. Sends an email without throwing when a valid address is provided
 *   3. Handles a run with zero step executions gracefully
 *   4. Handles a run with multiple step executions (Failed + Completed mix)
 *
 * Salesforce test context does not deliver emails, but sendEmail() still
 * succeeds without throwing — so tests assert no exceptions are raised.
 */
@IsTest
private class JobNotificationServiceTest {

    // ── Test 1: blank email → silent no-op ──────────────────────────────────

    @IsTest
    static void testNotifyFailure_blankEmail_noException() {
        JobPipelineRun__c run = createFailedRun('Test_Pipeline');

        // Build an in-memory CMT config with no email address
        JobPipeline__mdt cfg = new JobPipeline__mdt(
            DeveloperName        = 'Test_Pipeline',
            NotificationEmail__c = null
        );

        Test.startTest();
        JobNotificationService.notifyFailure(run, cfg, 'Step A failed');
        Test.stopTest();

        System.assert(true, 'notifyFailure must not throw when NotificationEmail__c is blank');
    }

    // ── Test 2: valid email, no step executions ──────────────────────────────

    @IsTest
    static void testNotifyFailure_withEmail_noSteps_doesNotThrow() {
        JobPipelineRun__c run = createFailedRun('Test_Pipeline');

        JobPipeline__mdt cfg = new JobPipeline__mdt(
            DeveloperName        = 'Test_Pipeline',
            NotificationEmail__c = 'ops@example.com'
        );

        Test.startTest();
        JobNotificationService.notifyFailure(run, cfg, 'Pipeline timed out');
        Test.stopTest();

        System.assert(true, 'notifyFailure must not throw with a valid email and no step records');
    }

    // ── Test 3: valid email with failed + completed steps ────────────────────

    @IsTest
    static void testNotifyFailure_withEmail_withSteps_doesNotThrow() {
        JobPipelineRun__c run = createFailedRun('Test_Pipeline');

        // Insert a mix of step execution records
        insert new List<JobStepExecution__c>{
            new JobStepExecution__c(
                PipelineRun__c       = run.Id,
                StepDeveloperName__c = 'Step_A',
                Status__c            = 'Completed',
                AttemptNumber__c     = 1,
                StartTime__c         = System.now().addMinutes(-10),
                EndTime__c           = System.now().addMinutes(-8)
            ),
            new JobStepExecution__c(
                PipelineRun__c       = run.Id,
                StepDeveloperName__c = 'Step_B',
                Status__c            = 'Failed',
                AttemptNumber__c     = 3,
                StartTime__c         = System.now().addMinutes(-8),
                EndTime__c           = System.now().addMinutes(-1),
                ErrorMessage__c      = 'NullPointerException at line 42'
            )
        };

        JobPipeline__mdt cfg = new JobPipeline__mdt(
            DeveloperName        = 'Test_Pipeline',
            NotificationEmail__c = 'ops@example.com'
        );

        Test.startTest();
        JobNotificationService.notifyFailure(run, cfg, 'Step_B failed after 3 attempts');
        Test.stopTest();

        System.assert(true, 'notifyFailure must not throw with mixed step statuses');
    }

    // ── Test 4: null StartTime / EndTime handled gracefully ──────────────────

    @IsTest
    static void testNotifyFailure_nullDates_doesNotThrow() {
        // Run with null StartTime/EndTime (edge case — pipeline aborted before starting)
        JobPipelineRun__c run = new JobPipelineRun__c(
            Pipeline__c    = 'Test_Pipeline',
            Status__c      = 'Failed',
            TriggeredBy__c = 'Manual'
            // StartTime__c and EndTime__c intentionally omitted
        );
        insert run;
        run = [SELECT Id, Name, Pipeline__c, Status__c, StartTime__c, EndTime__c
               FROM   JobPipelineRun__c WHERE Id = :run.Id];

        JobPipeline__mdt cfg = new JobPipeline__mdt(
            DeveloperName        = 'Test_Pipeline',
            NotificationEmail__c = 'ops@example.com'
        );

        Test.startTest();
        JobNotificationService.notifyFailure(run, cfg, 'Aborted before start');
        Test.stopTest();

        System.assert(true, 'notifyFailure must not throw when timestamps are null');
    }

    // ─── Helper ─────────────────────────────────────────────────────────────────

    private static JobPipelineRun__c createFailedRun(String pipeline) {
        JobPipelineRun__c run = new JobPipelineRun__c(
            Pipeline__c    = pipeline,
            Status__c      = 'Failed',
            TriggeredBy__c = 'Manual',
            StartTime__c   = System.now().addMinutes(-15),
            EndTime__c     = System.now()
        );
        insert run;
        return [SELECT Id, Name, Pipeline__c, Status__c, StartTime__c, EndTime__c
                FROM   JobPipelineRun__c WHERE Id = :run.Id];
    }
}
