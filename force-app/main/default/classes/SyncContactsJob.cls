/**
 * SyncContactsJob
 *
 * Sample batch job — Step 2a of the Nightly_Data_Sync pipeline.
 * Runs in PARALLEL with SyncCasesJob (same BranchGroup = Group_ParallelSync).
 * Guaranteed to start only after SyncAccountsJob completes.
 *
 * Reads 'accountsSyncedToday' from sharedContext written by SyncAccountsJob
 * to demonstrate cross-step data passing.
 *
 * ExecutionMode : Batch
 * BranchGroup   : Group_ParallelSync
 */
public class SyncContactsJob implements ISchedulableJob {

    // ── Batch mode ───────────────────────────────────────────────────────────

    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) {
        Integer lookbackHours = Integer.valueOf(
            ctx.getParameter('lookbackHours', 24)
        );
        DateTime cutoff = System.now().addHours(-lookbackHours);

        return Database.getQueryLocator([
            SELECT Id, LastName, AccountId, Description
            FROM   Contact
            WHERE  AccountId != null
            AND    LastModifiedDate >= :cutoff
        ]);
    }

    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {
        String syncNote = 'Synced by pipeline: ' + System.now().format();
        List<Contact> toUpdate = new List<Contact>();

        for (SObject record : scope) {
            Contact con = (Contact) record;
            con.Description = syncNote;
            toUpdate.add(con);
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
        Integer lookbackHours = Integer.valueOf(ctx.getParameter('lookbackHours', 24));
        DateTime cutoff = System.now().addHours(-lookbackHours);

        Integer contactsCount = [
            SELECT COUNT() FROM Contact WHERE LastModifiedDate >= :cutoff
        ];
        Integer accountsCount = (Integer) ctx.getSharedValue('accountsSyncedToday', 0);

        ctx.sharedContext.put('contactsSyncedToday', contactsCount);
        ctx.sharedContext.put('contactToAccountRatio',
            accountsCount > 0
                ? (Decimal) contactsCount / accountsCount
                : 0
        );
    }

    // ── Queueable mode (not used) ────────────────────────────────────────────

    public void execute(JobExecutionContext ctx) {}
}
