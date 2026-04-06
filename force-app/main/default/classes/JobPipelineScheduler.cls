/**
 * JobPipelineScheduler
 *
 * The ONLY class you register with System.schedule().
 * One instance per pipeline — pass the pipeline DeveloperName in the constructor.
 *
 * What it does (3 steps):
 *   1. Creates a JobPipelineRun__c record (Status = Queued).
 *   2. Enqueues JobOrchestrator with the new run Id.
 *   3. JobOrchestrator takes over from there — reads CMT config,
 *      resolves the DAG, and dispatches all steps in order.
 *
 * How to schedule via Anonymous Apex:
 *
 *   // Run Nightly_Data_Sync every day at 2 AM
 *   System.schedule(
 *       'Nightly Data Sync',
 *       '0 0 2 * * ?',
 *       new JobPipelineScheduler('Nightly_Data_Sync')
 *   );
 *
 * How to run immediately (one-off):
 *
 *   JobPipelineScheduler.runNow('Nightly_Data_Sync');
 */
public class JobPipelineScheduler implements Schedulable {

    private String pipelineDeveloperName;

    public JobPipelineScheduler(String pipelineDeveloperName) {
        this.pipelineDeveloperName = pipelineDeveloperName;
    }

    // Called by Salesforce on the cron schedule
    public void execute(SchedulableContext sc) {
        startPipeline(pipelineDeveloperName, 'Scheduler');
    }

    // ── Static helpers ───────────────────────────────────────────────────────

    /**
     * Trigger a pipeline immediately from Anonymous Apex or another class.
     * Does NOT require a cron schedule.
     */
    public static Id runNow(String pipelineDeveloperName) {
        return startPipeline(pipelineDeveloperName, 'Manual');
    }

    /**
     * Register this pipeline on its cron schedule defined in JobPipeline__mdt.
     * Call once from Anonymous Apex after deploying a new pipeline.
     *
     * Example:
     *   JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
     */
    public static String registerSchedule(String pipelineDeveloperName) {
        List<JobPipeline__mdt> pipelines = [
            SELECT CronExpression__c, MasterLabel
            FROM   JobPipeline__mdt
            WHERE  DeveloperName = :pipelineDeveloperName
            AND    IsActive__c   = true
            LIMIT  1
        ];

        if (pipelines.isEmpty()) {
            throw new IllegalArgumentException(
                'No active JobPipeline__mdt found with DeveloperName: ' + pipelineDeveloperName
            );
        }

        JobPipeline__mdt cfg = pipelines[0];

        if (String.isBlank(cfg.CronExpression__c)) {
            throw new IllegalArgumentException(
                'Pipeline ' + pipelineDeveloperName + ' has no CronExpression__c defined.'
            );
        }

        String jobName = 'Pipeline: ' + cfg.MasterLabel;

        // Abort any existing scheduled job with the same name before re-registering
        for (CronTrigger existing : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :jobName
        ]) {
            System.abortJob(existing.Id);
        }

        return System.schedule(
            jobName,
            cfg.CronExpression__c,
            new JobPipelineScheduler(pipelineDeveloperName)
        );
    }

    // ── Private ──────────────────────────────────────────────────────────────

    private static Id startPipeline(String pipelineDeveloperName, String triggeredBy) {
        // Guard: only start if pipeline is active
        List<JobPipeline__mdt> pipelines = [
            SELECT IsActive__c
            FROM   JobPipeline__mdt
            WHERE  DeveloperName = :pipelineDeveloperName
            LIMIT  1
        ];

        if (pipelines.isEmpty() || !pipelines[0].IsActive__c) {
            return null;
        }

        // Create the runtime run record
        JobPipelineRun__c run = new JobPipelineRun__c(
            Pipeline__c    = pipelineDeveloperName,
            Status__c      = 'Queued',
            TriggeredBy__c = triggeredBy
        );
        insert run;

        // Hand off to the orchestrator
        System.enqueueJob(new JobOrchestrator(run.Id));

        return run.Id;
    }
}
