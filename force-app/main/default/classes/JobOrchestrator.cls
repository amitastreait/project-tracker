/**
 * JobOrchestrator
 *
 * The central scheduling brain. Stateless Queueable — re-reads all config and
 * runtime state fresh on every invocation so it is safe across async transaction
 * boundaries and retry scenarios.
 *
 * Entry points:
 *   • JobPipelineScheduler enqueues this when a new run starts (Status = Queued).
 *   • JobCompletionTrigger re-enqueues this every time a step completes or fails.
 *
 * Each pass:
 *   1.  Guard: exit immediately if the run is already terminal or cancelled.
 *   2.  Transition run from Queued → Running on the very first pass.
 *   3.  Load CMT config (pipeline + steps + dependencies).
 *   4.  Load runtime state (all step executions for this run).
 *   5.  Phase 6: Per-step timeout watchdog — mark overdue Running steps as Failed.
 *   6.  Compute which steps are ready via JobDependencyResolver.
 *   7.  Apply pipeline failure policy (AbortPipeline vs ContinueOnError).
 *   8.  Dispatch all ready steps (respecting MaxConcurrentSteps__c and the
 *       50-enqueueJob-per-transaction governor limit).
 *   9.  If nothing is ready and nothing is running, close the pipeline.
 *   10. Phase 5: Send failure notification email on any terminal failure.
 */
public without sharing class JobOrchestrator implements Queueable {

    private Id pipelineRunId;

    public JobOrchestrator(Id pipelineRunId) {
        this.pipelineRunId = pipelineRunId;
    }

    public void execute(QueueableContext qc) {

        // ── 1. Load run record ───────────────────────────────────────────────
        JobPipelineRun__c run = [
            SELECT Id, Name, Pipeline__c, Status__c, ContextData__c,
                   StartTime__c, EndTime__c
            FROM   JobPipelineRun__c
            WHERE  Id = :pipelineRunId
            LIMIT  1
        ];

        // Guard: nothing to do if already in a terminal state
        if (run.Status__c == 'Completed' ||
            run.Status__c == 'Failed'    ||
            run.Status__c == 'Cancelled') {
            return;
        }

        // ── 2. Load pipeline CMT config ──────────────────────────────────────
        JobPipeline__mdt pipelineCfg = [
            SELECT DeveloperName, OnStepFailure__c, MaxConcurrentSteps__c,
                   MaxPipelineRuntime__c, NotificationEmail__c
            FROM   JobPipeline__mdt
            WHERE  DeveloperName = :run.Pipeline__c
            LIMIT  1
        ];

        // Check wall-clock timeout before doing anything
        if (isPipelineTimedOut(run, pipelineCfg)) {
            String timeoutMsg = 'Pipeline exceeded MaxPipelineRuntime of '
                              + pipelineCfg.MaxPipelineRuntime__c + ' minutes. Aborting.';
            closeRunAndNotify(run, 'Failed', pipelineCfg, timeoutMsg);
            return;
        }

        // ── 3. Transition Queued → Running ───────────────────────────────────
        if (run.Status__c == 'Queued') {
            run.Status__c    = 'Running';
            run.StartTime__c = System.now();
            update run;
        }

        // ── 4. Load all active steps + dependencies for this pipeline ────────
        List<JobStep__mdt> steps = [
            SELECT DeveloperName, ApexClassName__c, ExecutionMode__c, BatchSize__c,
                   ExecutionOrder__c, IsActive__c, TimeoutMinutes__c,
                   ExecutionParameters__c, BranchGroup__c, RetryPolicy__c, Pipeline__c
            FROM   JobStep__mdt
            WHERE  Pipeline__r.DeveloperName = :run.Pipeline__c
            AND    IsActive__c = true
            ORDER BY ExecutionOrder__c ASC NULLS LAST
        ];

        List<JobDependency__mdt> dependencies = [
            SELECT StepToRun__c, DependsOnStep__c
            FROM   JobDependency__mdt
            WHERE  Pipeline__r.DeveloperName = :run.Pipeline__c
        ];

        // ── 5. Build step status map from latest execution records ───────────
        //    ORDER BY AttemptNumber__c DESC so the first occurrence per step = latest attempt.
        List<JobStepExecution__c> executions = [
            SELECT Id, StepDeveloperName__c, Status__c, AttemptNumber__c, StartTime__c
            FROM   JobStepExecution__c
            WHERE  PipelineRun__c = :pipelineRunId
            ORDER BY AttemptNumber__c DESC
        ];

        Map<String, String> stepStatusByName = new Map<String, String>();
        Set<String> inProgressSteps = new Set<String>();

        for (JobStepExecution__c exec : executions) {
            // First occurrence per step name = latest attempt (due to ORDER BY DESC)
            if (!stepStatusByName.containsKey(exec.StepDeveloperName__c)) {
                stepStatusByName.put(exec.StepDeveloperName__c, exec.Status__c);
            }
            if (exec.Status__c == 'Running' || exec.Status__c == 'Retrying') {
                inProgressSteps.add(exec.StepDeveloperName__c);
            }
        }

        // ── Phase 6: Per-step timeout watchdog ───────────────────────────────
        // Check if any Running step has exceeded its TimeoutMinutes__c threshold.
        // Timed-out steps are marked Failed; the status map is updated so the
        // AbortPipeline / ContinueOnError logic below picks them up immediately.
        List<String> timedOutSteps = checkStepTimeouts(steps, executions, run.Id);
        for (String name : timedOutSteps) {
            stepStatusByName.put(name, 'Failed');
            inProgressSteps.remove(name);
        }

        // ── 6. Check for terminal failure with AbortPipeline policy ─────────
        if (pipelineCfg.OnStepFailure__c == 'AbortPipeline' &&
            stepStatusByName.values().contains('Failed')) {
            closeRunAndNotify(run, 'Failed', pipelineCfg,
                'Pipeline aborted — a step failed and OnStepFailure is AbortPipeline.');
            return;
        }

        // ── 7. With ContinueOnError: mark unreachable steps as Skipped ───────
        if (pipelineCfg.OnStepFailure__c == 'ContinueOnError') {
            List<String> unreachable = JobDependencyResolver.getUnreachableSteps(
                steps, dependencies, stepStatusByName
            );
            if (!unreachable.isEmpty()) {
                skipSteps(unreachable, pipelineRunId);
                for (String name : unreachable) {
                    stepStatusByName.put(name, 'Skipped');
                }
            }
        }

        // ── 8. Check if pipeline is fully complete ───────────────────────────
        if (isPipelineComplete(steps, stepStatusByName)) {
            Boolean hasFailures = stepStatusByName.values().contains('Failed');
            String  finalStatus = hasFailures ? 'Failed' : 'Completed';
            String  completionMsg = 'Pipeline ' + run.Pipeline__c + ' '
                                  + (hasFailures ? 'completed with failures.' : 'completed successfully.');
            closeRunAndNotify(run, finalStatus, pipelineCfg, completionMsg);
            return;
        }

        // ── 9. Resolve ready steps ───────────────────────────────────────────
        List<String> readyNames = JobDependencyResolver.getReadySteps(
            steps, dependencies, stepStatusByName
        );

        // Nothing ready and nothing running → deadlock
        if (readyNames.isEmpty() && inProgressSteps.isEmpty()) {
            closeRunAndNotify(run, 'Failed', pipelineCfg,
                'Pipeline deadlocked — no steps are ready and none are in progress. '
              + 'Check for configuration issues in JobDependency__mdt.');
            return;
        }

        // ── 10. Dispatch ready steps ─────────────────────────────────────────
        Map<String, JobStep__mdt> stepByName = new Map<String, JobStep__mdt>();
        for (JobStep__mdt step : steps) {
            stepByName.put(step.DeveloperName, step);
        }

        Integer maxDispatch = (pipelineCfg.MaxConcurrentSteps__c != null)
            ? Integer.valueOf(pipelineCfg.MaxConcurrentSteps__c)
            : 50;
        maxDispatch = Math.min(maxDispatch, 50);

        Integer dispatched = 0;
        for (String stepName : readyNames) {
            if (dispatched >= maxDispatch) break;

            JobStep__mdt step = stepByName.get(stepName);
            if (step == null) continue;

            try {
                JobDispatcher.dispatch(step, pipelineRunId, 1);
                dispatched++;
                log(run.Id, null, 'INFO', 'Dispatched step: ' + stepName);
            } catch (Exception ex) {
                log(run.Id, null, 'ERROR',
                    'Failed to dispatch step ' + stepName + ': ' + ex.getMessage());
            }
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    /**
     * Phase 6 — Per-step timeout watchdog.
     * Finds Running step executions that have exceeded their TimeoutMinutes__c limit,
     * marks them Failed, and returns the list of timed-out step names.
     */
    private List<String> checkStepTimeouts(
        List<JobStep__mdt>        steps,
        List<JobStepExecution__c> executions,
        Id                        runId
    ) {
        // Build a map of step DeveloperName → TimeoutMinutes__c (skip steps with no timeout)
        Map<String, Decimal> timeoutByStep = new Map<String, Decimal>();
        for (JobStep__mdt s : steps) {
            if (s.TimeoutMinutes__c != null) {
                timeoutByStep.put(s.DeveloperName, s.TimeoutMinutes__c);
            }
        }
        if (timeoutByStep.isEmpty()) return new List<String>();

        // Build map of step name → latest execution (ORDER BY AttemptNumber DESC, so first = latest)
        Map<String, JobStepExecution__c> latestByStep = new Map<String, JobStepExecution__c>();
        for (JobStepExecution__c exec : executions) {
            if (!latestByStep.containsKey(exec.StepDeveloperName__c)) {
                latestByStep.put(exec.StepDeveloperName__c, exec);
            }
        }

        List<String>                timedOut = new List<String>();
        List<JobStepExecution__c>   toFail   = new List<JobStepExecution__c>();

        for (String stepName : latestByStep.keySet()) {
            JobStepExecution__c exec = latestByStep.get(stepName);

            if (exec.Status__c    != 'Running')              continue;
            if (!timeoutByStep.containsKey(stepName))        continue;
            if (exec.StartTime__c == null)                   continue;

            Long elapsedMinutes = (System.now().getTime() - exec.StartTime__c.getTime()) / 60000;
            Decimal limitMinutes = timeoutByStep.get(stepName);

            if (elapsedMinutes >= Integer.valueOf(limitMinutes)) {
                String msg = 'Step timed out after ' + elapsedMinutes
                           + ' min (limit: ' + limitMinutes + ' min).';
                exec.Status__c       = 'Failed';
                exec.EndTime__c      = System.now();
                exec.ErrorMessage__c = msg;
                toFail.add(exec);
                timedOut.add(stepName);
                log(runId, exec.Id, 'ERROR', stepName + ': ' + msg);
            }
        }

        if (!toFail.isEmpty()) update toFail;
        return timedOut;
    }

    private Boolean isPipelineComplete(
        List<JobStep__mdt> steps,
        Map<String, String> stepStatusByName
    ) {
        for (JobStep__mdt step : steps) {
            String status = stepStatusByName.get(step.DeveloperName);
            if (status == null       ||
                status == 'Pending'  ||
                status == 'Running'  ||
                status == 'Retrying') {
                return false;
            }
        }
        return true;
    }

    private Boolean isPipelineTimedOut(JobPipelineRun__c run, JobPipeline__mdt cfg) {
        if (cfg.MaxPipelineRuntime__c == null || run.StartTime__c == null) return false;
        Long elapsedMinutes = (System.now().getTime() - run.StartTime__c.getTime()) / 60000;
        return elapsedMinutes > cfg.MaxPipelineRuntime__c;
    }

    /**
     * Closes the run, logs the reason, and — on failure — sends a notification email.
     * Phase 5: notification is wired in here so every failure path is covered
     * without duplicating calls at each site.
     */
    private void closeRunAndNotify(
        JobPipelineRun__c run,
        String            finalStatus,
        JobPipeline__mdt  cfg,
        String            reason
    ) {
        run.Status__c  = finalStatus;
        run.EndTime__c = System.now();
        update run;

        log(run.Id, null, finalStatus == 'Failed' ? 'ERROR' : 'INFO', reason);

        if (finalStatus == 'Failed') {
            JobNotificationService.notifyFailure(run, cfg, reason);
        }
    }

    private void skipSteps(List<String> stepNames, Id runId) {
        List<JobStepExecution__c> toInsert = new List<JobStepExecution__c>();
        for (String name : stepNames) {
            toInsert.add(new JobStepExecution__c(
                PipelineRun__c       = runId,
                StepDeveloperName__c = name,
                Status__c            = 'Skipped',
                AttemptNumber__c     = 1,
                StartTime__c         = System.now(),
                EndTime__c           = System.now()
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }

    private void log(Id runId, Id stepExecId, String level, String message) {
        insert new JobExecutionLog__c(
            PipelineRun__c   = runId,
            StepExecution__c = stepExecId,
            LogLevel__c      = level,
            Message__c       = message,
            Timestamp__c     = System.now()
        );
    }
}
