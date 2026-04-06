/**
 * SyncCasesJob
 *
 * Sample batch job — Step 2b of the Nightly_Data_Sync pipeline.
 * Runs in PARALLEL with SyncContactsJob (same BranchGroup = Group_ParallelSync).
 * GenerateReportsJob starts only after BOTH this and SyncContactsJob complete.
 *
 * Supports an optional 'caseStatus' parameter in ExecutionParameters__c JSON:
 *   {"caseStatus": "Open"}
 * When omitted, all cases modified in the lookback window are processed.
 *
 * ExecutionMode : Batch
 * BranchGroup   : Group_ParallelSync
 */
public class SyncCasesJob implements ISchedulableJob {

    // ── Batch mode ───────────────────────────────────────────────────────────

    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) {
        Integer lookbackHours = Integer.valueOf(
            ctx.getParameter('lookbackHours', 24)
        );
        DateTime cutoff = System.now().addHours(-lookbackHours);
        String statusFilter = (String) ctx.getParameter('caseStatus', null);

        // Use bind variables in dynamic SOQL (not date literals like LAST_N_HOURS)
        // so we can optionally filter by status at runtime
        String soql =
            'SELECT Id, CaseNumber, Status, Description ' +
            'FROM Case ' +
            'WHERE LastModifiedDate >= :cutoff';

        if (String.isNotBlank(statusFilter)) {
            soql += ' AND Status = :statusFilter';
        }

        return Database.getQueryLocator(soql);
    }

    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {
        String syncNote = 'Synced by pipeline: ' + System.now().format();
        List<Case> toUpdate = new List<Case>();

        for (SObject record : scope) {
            Case c = (Case) record;
            c.Description = syncNote;
            toUpdate.add(c);
        }

        List<Database.SaveResult> results = Database.update(toUpdate, false);

        Integer failed = 0;
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) failed++;
        }

        if (ctx.stepExecutionId != null) {
            update new JobStepExecution__c(
                Id                  = ctx.stepExecutionId,
                RecordsProcessed__c = scope.size() - failed,
                RecordsFailed__c    = failed
            );
        }
    }

    public void finishBatch(JobExecutionContext ctx) {
        // Aggregate case counts by status and store for GenerateReportsJob
        Map<String, Integer> caseCounts = new Map<String, Integer>();

        for (AggregateResult ar : [
            SELECT Status, COUNT(Id) total
            FROM   Case
            GROUP BY Status
        ]) {
            caseCounts.put(
                (String) ar.get('Status'),
                Integer.valueOf(ar.get('total'))
            );
        }

        ctx.sharedContext.put('caseCountsByStatus', caseCounts);
    }

    // ── Queueable mode (not used) ────────────────────────────────────────────

    public void execute(JobExecutionContext ctx) {}
}
