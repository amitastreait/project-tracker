/**
 * ISchedulableJob
 *
 * Integration contract for every job that participates in a pipeline.
 * JobDispatcher instantiates the concrete class via Type.forName() and validates
 * that it implements this interface before dispatching.
 *
 * Queueable steps: implement execute().
 * Batch steps    : implement getQueryLocator(), executeBatch(), and finishBatch().
 *                  The three batch methods are ignored by JobQueueableWrapper.
 *                  execute() is ignored by JobBatchWrapper.
 */
public interface ISchedulableJob {

    /**
     * Called by JobQueueableWrapper when ExecutionMode = Queueable.
     * Implement all business logic here for non-batch jobs.
     */
    void execute(JobExecutionContext ctx);

    /**
     * Called by JobBatchWrapper.start() when ExecutionMode = Batch.
     * Return the query locator that drives the batch scope.
     */
    Database.QueryLocator getQueryLocator(JobExecutionContext ctx);

    /**
     * Called by JobBatchWrapper.execute() for each chunk of records.
     * Implement the per-chunk processing logic here.
     */
    void executeBatch(JobExecutionContext ctx, List<SObject> scope);

    /**
     * Called by JobBatchWrapper.finish() after all chunks complete.
     * Use this for post-processing, aggregation, or signalling downstream.
     * Do NOT publish JobCompletionEvent__e here — the wrapper handles that.
     */
    void finishBatch(JobExecutionContext ctx);
}
