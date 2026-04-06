/**
 * GenerateReportsJob
 *
 * Sample Queueable job — Final step of the Nightly_Data_Sync pipeline.
 * Runs only after BOTH SyncContactsJob AND SyncCasesJob complete (AND-join).
 *
 * Reads accumulated data from sharedContext written by all upstream steps:
 *   - accountsSyncedToday  (from SyncAccountsJob)
 *   - contactsSyncedToday  (from SyncContactsJob)
 *   - contactToAccountRatio(from SyncContactsJob)
 *   - caseCountsByStatus   (from SyncCasesJob)
 *
 * Then optionally emails results based on ExecutionParameters__c:
 *   {"reportType":"summary","emailResults":true}
 *
 * ExecutionMode : Queueable
 * BranchGroup   : (none) — final step
 */
public class GenerateReportsJob implements ISchedulableJob {

    // ── Queueable mode ───────────────────────────────────────────────────────

    public void execute(JobExecutionContext ctx) {
        // Read all values written by upstream steps via sharedContext
        Integer accounts = (Integer) ctx.getSharedValue('accountsSyncedToday', 0);
        Integer contacts = (Integer) ctx.getSharedValue('contactsSyncedToday', 0);
        Decimal ratio    = (Decimal) ctx.getSharedValue('contactToAccountRatio', 0);

        Map<String, Object> rawCaseCounts =
            (Map<String, Object>) ctx.getSharedValue('caseCountsByStatus', new Map<String, Object>());

        // Read job-level parameters from ExecutionParameters__c JSON
        String  reportType   = (String)  ctx.getParameter('reportType', 'summary');
        Boolean emailResults = (Boolean) ctx.getParameter('emailResults', false);

        // Build the report body
        String reportBody = buildReport(reportType, accounts, contacts, ratio, rawCaseCounts);

        // Store the report in sharedContext (could be picked up by a future step)
        ctx.sharedContext.put('lastReportBody', reportBody);
        ctx.sharedContext.put('lastReportDate', String.valueOf(System.today()));

        // Optionally email the report
        if (emailResults) {
            sendReportEmail(ctx, reportBody);
        }

        // Update the step execution with a record count (1 report generated)
        if (ctx.stepExecutionId != null) {
            update new JobStepExecution__c(
                Id                  = ctx.stepExecutionId,
                RecordsProcessed__c = 1
            );
        }
    }

    // ── Batch mode (not used — ExecutionMode = Queueable) ───────────────────

    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) {
        return null;
    }

    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {}

    public void finishBatch(JobExecutionContext ctx) {}

    // ── Private helpers ──────────────────────────────────────────────────────

    private String buildReport(
        String reportType,
        Integer accounts,
        Integer contacts,
        Decimal ratio,
        Map<String, Object> caseCounts
    ) {
        String nl = '\n';
        String body = '=== Nightly Sync Report — ' + System.today() + ' ===' + nl + nl;

        if (reportType == 'summary' || reportType == 'full') {
            body += 'ACCOUNTS' + nl;
            body += '  Synced today : ' + accounts + nl + nl;

            body += 'CONTACTS' + nl;
            body += '  Synced today             : ' + contacts + nl;
            body += '  Contact-to-Account ratio : ' + ratio.setScale(2) + nl + nl;

            body += 'CASES BY STATUS' + nl;
            for (String status : caseCounts.keySet()) {
                body += '  ' + status + ' : ' + caseCounts.get(status) + nl;
            }
        }

        return body;
    }

    private void sendReportEmail(JobExecutionContext ctx, String reportBody) {
        // Load the notification email from the pipeline config
        List<JobPipeline__mdt> pipelines = [
            SELECT NotificationEmail__c
            FROM   JobPipeline__mdt
            WHERE  DeveloperName = :ctx.pipelineDeveloperName
            LIMIT  1
        ];

        if (pipelines.isEmpty() || String.isBlank(pipelines[0].NotificationEmail__c)) {
            return;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ pipelines[0].NotificationEmail__c });
        mail.setSubject('Nightly Sync Report — ' + System.today());
        mail.setPlainTextBody(reportBody);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
    }
}
