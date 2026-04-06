/**
 * SyncAccountsJob
 *
 * Sample batch job — Step 1 of the Nightly_Data_Sync pipeline.
 * Finds Accounts modified in the last N hours and stamps their Description
 * with a sync note. Writes the synced count into sharedContext so downstream
 * steps (SyncContactsJob, GenerateReportsJob) can read it.
 *
 * ExecutionMode : Batch
 * BranchGroup   : (none) — runs first, gates the parallel branch
 */
public class SyncAccountsJob implements ISchedulableJob {

    // ── Batch mode ───────────────────────────────────────────────────────────

    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) {
        Integer lookbackHours = Integer.valueOf(
            ctx.getParameter('lookbackHours', 24)
        );
        DateTime cutoff = System.now().addHours(-lookbackHours);

        return Database.getQueryLocator([
            SELECT Id, Name, Description
            FROM   Account
            WHERE  LastModifiedDate >= :cutoff
        ]);
    }

    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {
        String syncNote = 'Synced by pipeline: ' + System.now().format();
        List<Account> toUpdate = new List<Account>();

        for (SObject record : scope) {
            Account acc = (Account) record;
            acc.Description = syncNote;
            toUpdate.add(acc);
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
        // Write total into sharedContext for downstream steps to read
        Integer lookbackHours = Integer.valueOf(ctx.getParameter('lookbackHours', 24));
        DateTime cutoff = System.now().addHours(-lookbackHours);

        Integer syncedCount = [
            SELECT COUNT() FROM Account WHERE LastModifiedDate >= :cutoff
        ];
        ctx.sharedContext.put('accountsSyncedToday', syncedCount);
    }

    // ── Queueable mode (not used — ExecutionMode = Batch) ───────────────────

    public void execute(JobExecutionContext ctx) {}
}
