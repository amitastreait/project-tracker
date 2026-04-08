/**
 * JobNotificationService — Phase 5
 *
 * Sends a plain-text failure notification email to the pipeline's
 * NotificationEmail__c address whenever a pipeline run closes as Failed.
 *
 * Called by JobOrchestrator after every terminal failure (step failure with
 * AbortPipeline, pipeline timeout, or deadlock).
 *
 * Email failures are caught and debug-logged so that a broken email config
 * never blocks the pipeline state update.
 */
public without sharing class JobNotificationService {

    /**
     * Send a failure notification for a closed pipeline run.
     * No-ops silently when NotificationEmail__c is blank.
     *
     * @param run         The terminal JobPipelineRun__c — must include
     *                    Id, Name, Pipeline__c, Status__c, StartTime__c, EndTime__c
     * @param pipelineCfg The parent JobPipeline__mdt record
     * @param reason      Human-readable description of why the pipeline failed
     */
    public static void notifyFailure(
        JobPipelineRun__c run,
        JobPipeline__mdt  pipelineCfg,
        String            reason
    ) {
        if (String.isBlank(pipelineCfg.NotificationEmail__c)) return;

        // Pull the step summary for the email body
        List<JobStepExecution__c> execs = [
            SELECT StepDeveloperName__c, Status__c, AttemptNumber__c,
                   StartTime__c, EndTime__c, ErrorMessage__c
            FROM   JobStepExecution__c
            WHERE  PipelineRun__c = :run.Id
            ORDER BY StartTime__c ASC NULLS LAST
        ];

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ pipelineCfg.NotificationEmail__c });
        mail.setSubject('[Job Scheduler] Pipeline FAILED: ' + pipelineCfg.DeveloperName);
        mail.setPlainTextBody(buildBody(run, pipelineCfg, reason, execs));
        mail.setSaveAsActivity(false);

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception ex) {
            // Never let an email failure block the pipeline state record update
            System.debug(LoggingLevel.ERROR,
                'JobNotificationService: sendEmail failed — ' + ex.getMessage());
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    private static String buildBody(
        JobPipelineRun__c         run,
        JobPipeline__mdt          cfg,
        String                    reason,
        List<JobStepExecution__c> execs
    ) {
        final String nl = '\n';

        String body =
              'PIPELINE FAILURE NOTIFICATION'                    + nl
            + '==============================='                  + nl + nl
            + 'Pipeline  : ' + cfg.DeveloperName                + nl
            + 'Run ID    : ' + run.Name                         + nl
            + 'Status    : ' + run.Status__c                    + nl
            + 'Started   : ' + formatDt(run.StartTime__c)       + nl
            + 'Ended     : ' + formatDt(run.EndTime__c)         + nl
            + 'Reason    : ' + reason                           + nl + nl
            + 'STEP SUMMARY'                                    + nl
            + '────────────'                                    + nl;

        if (execs.isEmpty()) {
            body += '(no steps were executed)' + nl;
        } else {
            for (JobStepExecution__c e : execs) {
                body += '[' + e.Status__c + '] '
                     + e.StepDeveloperName__c
                     + ' (attempt ' + Integer.valueOf(e.AttemptNumber__c) + ')';
                if (String.isNotBlank(e.ErrorMessage__c)
                    && (e.Status__c == 'Failed' || e.Status__c == 'Retrying')) {
                    body += nl + '  Error: ' + e.ErrorMessage__c;
                }
                body += nl;
            }
        }

        body += nl + 'View run in Salesforce:'
             + nl + System.Url.getOrgDomainUrl().toExternalForm() + '/' + run.Id;

        return body;
    }

    private static String formatDt(DateTime dt) {
        return dt == null ? 'N/A' : dt.format('yyyy-MM-dd HH:mm:ss');
    }
}
