# Job Scheduler — Usage Guide

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Reference](#2-component-reference)
3. [Data Flow — How a Pipeline Runs](#3-data-flow--how-a-pipeline-runs)
4. [Admin Setup Checklist](#4-admin-setup-checklist)
5. [Creating a Pipeline (Admin UI)](#5-creating-a-pipeline-admin-ui)
6. [Creating a Pipeline (Source / Deployment)](#6-creating-a-pipeline-source--deployment)
7. [Adding a New Job Class (Developer)](#7-adding-a-new-job-class-developer)
8. [Running & Scheduling a Pipeline](#8-running--scheduling-a-pipeline)
9. [Passing Parameters to a Job](#9-passing-parameters-to-a-job)
10. [Passing Data Between Steps](#10-passing-data-between-steps)
11. [Monitoring & Troubleshooting](#11-monitoring--troubleshooting)
12. [Configuration Reference](#12-configuration-reference)
13. [Governor Limit Handling](#13-governor-limit-handling)

---

## 1. Architecture Overview

The Job Scheduler is a **config-driven Apex job orchestration framework**. Execution order is controlled entirely through Custom Metadata Type (CMT) records — adding, removing, or reordering jobs never requires a code change or deployment.

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CONFIGURATION LAYER                          │
│   (Custom Metadata Types — deployed once, edited by Admin in UI)    │
│                                                                     │
│  JobPipeline__mdt      JobStep__mdt       JobDependency__mdt        │
│  ─────────────────      ────────────       ─────────────────        │
│  Nightly_Data_Sync  →  Sync_Accounts  →  (no deps — runs first)     │
│                     →  Sync_Contacts  →  depends on Sync_Accounts   │
│                     →  Sync_Cases     →  depends on Sync_Accounts   │
│                     →  Gen_Reports    →  depends on Contacts+Cases  │
│                                                                     │
│  JobRetryPolicy__mdt                                                │
│  ────────────────────                                               │
│  Standard_Retry  (MaxRetries=3, RetryDelay=60s)                     │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ reads at runtime
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ORCHESTRATION ENGINE                        │
│                                                                     │
│  JobPipelineScheduler  ──►  JobOrchestrator  ──►  JobDispatcher    │
│  (entry point)              (DAG evaluator)        (job launcher)   │
│                                 ▲                                   │
│                                 │ re-triggers via Platform Event    │
│  JobCompletionTrigger  ◄────────┘                                   │
│  (on JobCompletionEvent__e)                                         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ executes
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           JOB WRAPPERS                              │
│                                                                     │
│  JobQueueableWrapper          JobBatchWrapper                       │
│  (for Queueable steps)        (for Batch steps)                     │
│           │                          │                              │
│           └──────── delegates to ────┘                              │
│                    ISchedulableJob                                  │
│              (your job class implements this)                       │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ writes runtime state to
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          RUNTIME OBJECTS                            │
│                                                                     │
│  JobPipelineRun__c  ──MasterDetail──►  JobStepExecution__c          │
│  (one per pipeline run)                (one per step per attempt)   │
│         │                                                           │
│         └──MasterDetail──►  JobExecutionLog__c                      │
│                              (audit trail — INFO / ERROR entries)   │
└─────────────────────────────────────────────────────────────────────┘
```

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| Config-driven order | DAG edges in `JobDependency__mdt` — no code to rewire jobs |
| Infinite pipeline depth | `JobCompletionEvent__e` trigger resets Queueable chain depth each step |
| Stateless orchestrator | Re-reads all config + state fresh on every invocation |
| Cross-step shared data | `JobPipelineRun__c.ContextData__c` — JSON persisted after each step |
| Parallel steps | Same `BranchGroup__c` value → dispatched simultaneously |
| AND-join | Multiple `JobDependency__mdt` edges to the same `StepToRun__c` |
| Retry | `JobRetryPolicy__mdt` per step — max attempts, delay, exception filter |

---

## 2. Component Reference

### Custom Metadata Types (Configuration — editable in Setup UI)

| CMT | Purpose | Who edits |
|-----|---------|-----------|
| `JobPipeline__mdt` | Defines a pipeline (name, schedule, failure policy) | Admin |
| `JobStep__mdt` | One record per job in a pipeline | Admin / Developer |
| `JobDependency__mdt` | Execution order edges (which step waits for which) | Admin |
| `JobRetryPolicy__mdt` | Retry rules reused across steps | Admin |

### Custom Objects (Runtime — written by the engine, read by Admin/Ops)

| Object | Purpose | Created by |
|--------|---------|-----------|
| `JobPipelineRun__c` | One record per pipeline execution | `JobPipelineScheduler` |
| `JobStepExecution__c` | One record per step attempt | `JobDispatcher` |
| `JobExecutionLog__c` | INFO / ERROR audit messages | `JobOrchestrator`, wrappers |

### Platform Event

| Event | Purpose |
|-------|---------|
| `JobCompletionEvent__e` | Published by wrappers after each step; consumed by `JobCompletionTrigger` to re-enter the orchestrator |

### Apex Classes (Developer-owned)

| Class | Role |
|-------|------|
| `JobPipelineScheduler` | Entry point — `runNow()`, `registerSchedule()`, Schedulable |
| `JobOrchestrator` | DAG evaluation, step dispatch, run lifecycle management |
| `JobDispatcher` | Instantiates the job class, creates `JobStepExecution__c`, calls `enqueueJob`/`executeBatch` |
| `JobDependencyResolver` | Pure DAG logic — `getReadySteps()`, cycle detection |
| `JobQueueableWrapper` | Wraps Queueable jobs, handles success/failure, publishes event |
| `JobBatchWrapper` | Wraps Batch jobs, accumulates counts, publishes event in finish() |
| `JobExecutionContext` | Value object passed to every job — parameters, sharedContext, IDs |
| `ISchedulableJob` | Interface every job class must implement |

---

## 3. Data Flow — How a Pipeline Runs

```
1. TRIGGER
   Admin calls JobPipelineScheduler.runNow('Nightly_Data_Sync')
   OR Salesforce cron fires JobPipelineScheduler.execute()
         │
         ▼
2. CREATE RUN RECORD
   JobPipelineRun__c inserted  (Status = Queued)
   JobOrchestrator enqueued
         │
         ▼
3. ORCHESTRATOR — PASS 1
   Reads JobPipelineRun__c + all CMT config
   Transitions run: Queued → Running
   Evaluates DAG: Sync_Accounts has no dependencies → READY
   Calls JobDispatcher.dispatch(Sync_Accounts, ...)
         │
         ▼
4. DISPATCH STEP
   JobDispatcher:
     a. Type.forName('SyncAccountsJob') → instantiates class
     b. INSERT JobStepExecution__c (Status = Running)
     c. Database.executeBatch(new JobBatchWrapper(job, ctx))
         │
         ▼
5. BATCH EXECUTES
   JobBatchWrapper.start()   → calls SyncAccountsJob.getQueryLocator()
   JobBatchWrapper.execute() → calls SyncAccountsJob.executeBatch()  [repeated]
   JobBatchWrapper.finish()  → calls SyncAccountsJob.finishBatch()
                               UPDATE JobStepExecution__c (Status = Completed)
                               UPDATE JobPipelineRun__c.ContextData__c (sharedContext JSON)
                               EventBus.publish(JobCompletionEvent__e)
         │
         ▼
6. PLATFORM EVENT FIRES  (new transaction — Queueable depth resets to 0)
   JobCompletionTrigger.on JobCompletionEvent__e
   System.enqueueJob(new JobOrchestrator(runId))
         │
         ▼
7. ORCHESTRATOR — PASS 2
   Reads current status: Sync_Accounts = Completed
   DAG evaluation:
     Sync_Contacts → depends on Sync_Accounts (Completed) → READY
     Sync_Cases    → depends on Sync_Accounts (Completed) → READY
   Both have BranchGroup = 'Group_ParallelSync' → dispatched simultaneously
         │
         ▼
8. STEPS RUN IN PARALLEL
   Both complete → two JobCompletionEvent__e events published
   Two orchestrator re-entries (deduplicated by run ID)
         │
         ▼
9. ORCHESTRATOR — PASS 3  (after both parallel steps complete)
   Sync_Contacts = Completed, Sync_Cases = Completed
   Generate_Reports → depends on BOTH → READY
   Dispatches Generate_Reports
         │
         ▼
10. FINAL STEP COMPLETES
    Orchestrator evaluates: all 4 steps = Completed
    UPDATE JobPipelineRun__c Status = Completed, EndTime = now()
    LOG: "Pipeline Nightly_Data_Sync completed successfully."
```

---

## 4. Admin Setup Checklist

Complete these steps once after the initial deployment.

### 4.1 Assign the Permission Set

1. Go to **Setup → Users → Users**
2. Click the user who needs access
3. Scroll to **Permission Set Assignments** → click **Edit Assignments**
4. Move **Project Tracking Permission Set** to the Enabled list → **Save**

Repeat for every user who will trigger pipelines, monitor runs, or configure CMTs.

### 4.2 Verify Custom Tabs are Visible

1. Go to **Setup → Tabs**
2. Confirm these tabs exist and are active:
   - **Job Pipeline Runs** (`JobPipelineRun__c`)
   - **Job Step Executions** (`JobStepExecution__c`)
   - **Job Execution Logs** (`JobExecutionLog__c`)

### 4.3 Add Tabs to the App (if needed)

1. Go to **Setup → App Manager**
2. Find **Job Scheduler** → click **Edit**
3. Under **Navigation Items**, add the three tabs above → **Save**

### 4.4 Register the Pipeline Schedule

From **Setup → Developer Console → Execute Anonymous**:

```apex
// Register the cron schedule defined in the CMT (daily at 2 AM)
JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
```

To verify: **Setup → Scheduled Jobs** — you should see `Pipeline: Nightly Data Sync`.

### 4.5 Verify Platform Event Trigger

1. Go to **Setup → Apex Triggers**
2. Confirm **JobCompletionTrigger** is present and **Active**

> This trigger is the bridge between step completion and orchestrator re-entry.
> If it is inactive or missing, the pipeline will stop after the first step.

---

## 5. Creating a Pipeline (Admin UI)

Admins can create and modify pipelines entirely through the Salesforce Setup UI — no deployment required.

### Step 1 — Create the Pipeline record

1. Go to **Setup → Custom Metadata Types**
2. Click **Manage Records** next to **Job Pipeline**
3. Click **New**
4. Fill in:

| Field | Value | Notes |
|-------|-------|-------|
| Label | `Nightly Data Sync` | Human-readable name |
| Name (DeveloperName) | `Nightly_Data_Sync` | Auto-filled; used in code |
| Is Active | ✓ checked | Uncheck to disable without deleting |
| Cron Expression | `0 0 2 * * ?` | Daily at 2 AM — see cron reference below |
| On Step Failure | `AbortPipeline` | Or `ContinueOnError` |
| Max Concurrent Steps | `10` | Steps dispatched per orchestrator pass |
| Max Pipeline Runtime (min) | `120` | Wall-clock timeout; blank = no limit |
| Notification Email | `ops@company.com` | Optional alert on failure |

5. **Save**

**Cron Expression reference:**

```
Seconds  Minutes  Hours  Day-of-month  Month  Day-of-week  Year(optional)
   0        0       2         *           *         ?
```

| Example | Expression |
|---------|-----------|
| Daily at 2 AM | `0 0 2 * * ?` |
| Every Monday at 6 AM | `0 0 6 ? * MON` |
| Every hour | `0 0 * * * ?` |
| Every 15 minutes | `0 0/15 * * * ?` |
| Weekdays at 8 PM | `0 0 20 ? * MON-FRI` |

---

### Step 2 — Create the Retry Policy (optional, reusable)

1. **Setup → Custom Metadata Types → Job Retry Policy → Manage Records → New**

| Field | Value |
|-------|-------|
| Label | `Standard Retry` |
| Name | `Standard_Retry` |
| Max Retries | `3` |
| Retry Delay (seconds) | `60` |
| Retry Only On Exceptions | unchecked |
| Retry Exception Types | *(blank = retry on any failure)* |

---

### Step 3 — Create Job Step records

One record per Apex class. Repeat for each step.

1. **Setup → Custom Metadata Types → Job Step → Manage Records → New**

| Field | Value | Notes |
|-------|-------|-------|
| Label | `Sync Accounts` | Human-readable |
| Name | `Sync_Accounts` | Must match `DependsOnStep__c` / `StepToRun__c` exactly |
| Pipeline | `Nightly_Data_Sync` | Lookup to the pipeline CMT |
| Apex Class Name | `SyncAccountsJob` | Must match the deployed class name exactly |
| Execution Mode | `Batch` | Or `Queueable` |
| Batch Size | `200` | Batch only; default 200 |
| Execution Order | `10` | Controls display order; does NOT define run order (that is `JobDependency__mdt`) |
| Is Active | ✓ | Uncheck to skip this step without deleting |
| Timeout (minutes) | `30` | Step-level watchdog |
| Branch Group | *(blank)* | Fill to run steps in parallel (see below) |
| Retry Policy | `Standard_Retry` | Lookup to the retry policy CMT |
| Execution Parameters | `{"lookbackHours":24}` | JSON blob; read by the job via `ctx.getParameter()` |

**Parallel steps:** give two or more steps the same **Branch Group** value (e.g. `Group_Parallel`). The orchestrator dispatches all steps in the same group in one pass.

---

### Step 4 — Create Dependency records (execution order)

One record per dependency edge.

1. **Setup → Custom Metadata Types → Job Dependency → Manage Records → New**

| Field | Value |
|-------|-------|
| Label | `Contacts After Accounts` |
| Name | `Contacts_After_Accounts` |
| Pipeline | `Nightly_Data_Sync` |
| Step To Run | `Sync_Contacts` ← the step that must WAIT |
| Depends On Step | `Sync_Accounts` ← the step that must FINISH first |

**Rules:**
- A step with **no** dependency record runs immediately when the pipeline starts.
- For an AND-join (step waits for multiple predecessors), create one dependency record per predecessor — all pointing to the same `Step To Run`.
- Do not create circular dependencies (`A→B→A`) — the engine detects and rejects them.

**Example — the Nightly_Data_Sync dependency graph:**

```
Sync_Accounts  (no deps)
    │
    ├──► Sync_Contacts  (BranchGroup: Group_ParallelSync)
    │
    └──► Sync_Cases     (BranchGroup: Group_ParallelSync)
              │
              └──► Generate_Reports  ◄── (also depends on Sync_Contacts)
```

Dependency records needed:

| Label | Step To Run | Depends On Step |
|-------|------------|-----------------|
| `Contacts After Accounts` | `Sync_Contacts` | `Sync_Accounts` |
| `Cases After Accounts` | `Sync_Cases` | `Sync_Accounts` |
| `Reports After Contacts` | `Generate_Reports` | `Sync_Contacts` |
| `Reports After Cases` | `Generate_Reports` | `Sync_Cases` |

---

## 6. Creating a Pipeline (Source / Deployment)

For version-controlled environments, define CMT records as XML files and deploy with Salesforce CLI.

### File structure

```
force-app/main/default/
├── customMetadata/
│   ├── JobPipeline__mdt.My_Pipeline.md-meta.xml
│   ├── JobStep__mdt.Step_A.md-meta.xml
│   ├── JobStep__mdt.Step_B.md-meta.xml
│   ├── JobDependency__mdt.B_After_A.md-meta.xml
│   └── JobRetryPolicy__mdt.Standard_Retry.md-meta.xml
└── classes/
    ├── StepAJob.cls
    └── StepBJob.cls
```

### JobPipeline__mdt record

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>My Pipeline</label>
    <protected>false</protected>
    <values><field>IsActive__c</field>
        <value xsi:type="xsd:boolean">true</value></values>
    <values><field>CronExpression__c</field>
        <value xsi:type="xsd:string">0 0 2 * * ?</value></values>
    <values><field>OnStepFailure__c</field>
        <value xsi:type="xsd:string">AbortPipeline</value></values>
    <values><field>MaxConcurrentSteps__c</field>
        <value xsi:type="xsd:double">10.0</value></values>
    <values><field>MaxPipelineRuntime__c</field>
        <value xsi:type="xsd:double">120.0</value></values>
    <values><field>NotificationEmail__c</field>
        <value xsi:type="xsd:string">ops@company.com</value></values>
</CustomMetadata>
```

### JobStep__mdt record

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Step A</label>
    <protected>false</protected>
    <values><field>Pipeline__c</field>
        <value xsi:type="xsd:string">My_Pipeline</value></values>
    <values><field>ApexClassName__c</field>
        <value xsi:type="xsd:string">StepAJob</value></values>
    <values><field>ExecutionMode__c</field>
        <value xsi:type="xsd:string">Batch</value></values>
    <values><field>BatchSize__c</field>
        <value xsi:type="xsd:double">200.0</value></values>
    <values><field>ExecutionOrder__c</field>
        <value xsi:type="xsd:double">10.0</value></values>
    <values><field>IsActive__c</field>
        <value xsi:type="xsd:boolean">true</value></values>
    <values><field>TimeoutMinutes__c</field>
        <value xsi:type="xsd:double">30.0</value></values>
    <values><field>BranchGroup__c</field>
        <value xsi:nil="true"/></values>
    <values><field>RetryPolicy__c</field>
        <value xsi:type="xsd:string">Standard_Retry</value></values>
    <values><field>ExecutionParameters__c</field>
        <value xsi:type="xsd:string">{"lookbackHours": 24}</value></values>
</CustomMetadata>
```

### JobDependency__mdt record

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>B After A</label>
    <protected>false</protected>
    <values><field>Pipeline__c</field>
        <value xsi:type="xsd:string">My_Pipeline</value></values>
    <values><field>StepToRun__c</field>
        <value xsi:type="xsd:string">Step_B</value></values>
    <values><field>DependsOnStep__c</field>
        <value xsi:type="xsd:string">Step_A</value></values>
</CustomMetadata>
```

### Deploy

```bash
sf project deploy start --source-dir force-app --target-org <org-alias>
```

---

## 7. Adding a New Job Class (Developer)

Every job must implement `ISchedulableJob`. The interface has four methods — implement only those relevant to your execution mode.

```apex
public interface ISchedulableJob {
    // Queueable mode — implement this
    void execute(JobExecutionContext ctx);

    // Batch mode — implement these three
    Database.QueryLocator getQueryLocator(JobExecutionContext ctx);
    void executeBatch(JobExecutionContext ctx, List<SObject> scope);
    void finishBatch(JobExecutionContext ctx);
}
```

### Queueable job template

```apex
public class MyQueueableJob implements ISchedulableJob {

    public void execute(JobExecutionContext ctx) {
        // Read step parameters from ExecutionParameters__c JSON
        Integer maxRecords = Integer.valueOf(ctx.getParameter('maxRecords', 1000));

        // Read data written by an upstream step
        String upstream = (String) ctx.getSharedValue('upstreamOutput', null);

        // Your business logic here
        List<Account> accounts = [SELECT Id FROM Account LIMIT :maxRecords];
        // ...

        // Write data for downstream steps
        ctx.sharedContext.put('myJobOutput', accounts.size());
    }

    // Required stubs for Batch mode (leave empty for Queueable jobs)
    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) { return null; }
    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {}
    public void finishBatch(JobExecutionContext ctx) {}
}
```

### Batch job template

```apex
public class MyBatchJob implements ISchedulableJob {

    public Database.QueryLocator getQueryLocator(JobExecutionContext ctx) {
        Integer hours = Integer.valueOf(ctx.getParameter('lookbackHours', 24));
        DateTime cutoff = System.now().addHours(-hours);
        return Database.getQueryLocator([
            SELECT Id, Name FROM Account WHERE LastModifiedDate >= :cutoff
        ]);
    }

    public void executeBatch(JobExecutionContext ctx, List<SObject> scope) {
        // Runs once per batch chunk — keep governor limits in mind
        List<Account> toUpdate = new List<Account>();
        for (Account a : (List<Account>) scope) {
            a.Description = 'Processed by scheduler';
            toUpdate.add(a);
        }
        update toUpdate;
    }

    public void finishBatch(JobExecutionContext ctx) {
        // Runs once after all chunks complete
        // sharedContext is persisted automatically after finishBatch()
        ctx.sharedContext.put('processedCount', 'done');
    }

    public void execute(JobExecutionContext ctx) {} // Not used in Batch mode
}
```

### Rules for job classes

| Rule | Reason |
|------|--------|
| Implement `ISchedulableJob` exactly | The dispatcher uses `Type.forName` + interface cast |
| Be idempotent | Retry logic may execute the same step more than once |
| Never publish `JobCompletionEvent__e` | The wrappers do this automatically |
| Never set `JobStepExecution__c.Status__c` | The wrappers own the step lifecycle |
| Use `ctx.sharedContext` for cross-step data | Automatically persisted to `JobPipelineRun__c.ContextData__c` |
| Use `ctx.getParameter()` for config | Reads from `ExecutionParameters__c` JSON on the CMT record |
| Use `ctx.stepExecutionId` for record updates | The `JobStepExecution__c` Id for this attempt |

---

## 8. Running & Scheduling a Pipeline

### Option A — Immediate run (Anonymous Apex)

```apex
Id runId = JobPipelineScheduler.runNow('Nightly_Data_Sync');
System.debug('Run created: ' + runId);
```

Returns `null` if the pipeline DeveloperName does not exist or `IsActive__c` is false.

### Option B — Register the cron schedule from the CMT

```apex
// Reads CronExpression__c from the JobPipeline__mdt record
String cronJobId = JobPipelineScheduler.registerSchedule('Nightly_Data_Sync');
System.debug('Scheduled job: ' + cronJobId);
```

Calling this again on an already-scheduled pipeline **replaces** the existing schedule (safe to re-run after CMT changes).

### Option C — Custom cron expression

```apex
System.schedule(
    'My Custom Schedule',
    '0 30 1 ? * MON-FRI',   // weekdays at 1:30 AM
    new JobPipelineScheduler('Nightly_Data_Sync')
);
```

### Verify the schedule

**Setup → Scheduled Jobs** — look for `Pipeline: Nightly Data Sync`

Or via SOQL:
```apex
SELECT Id, CronJobDetail.Name, NextFireTime, State
FROM CronTrigger
WHERE CronJobDetail.Name LIKE 'Pipeline:%'
ORDER BY NextFireTime ASC;
```

### Abort a scheduled pipeline

```apex
// Find and abort the scheduled job
for (CronTrigger ct : [
    SELECT Id FROM CronTrigger
    WHERE CronJobDetail.Name = 'Pipeline: Nightly Data Sync'
]) {
    System.abortJob(ct.Id);
}
```

---

## 9. Passing Parameters to a Job

Set `ExecutionParameters__c` on the `JobStep__mdt` record as a JSON string:

```json
{"lookbackHours": 48, "batchSize": 500, "emailResults": true, "targetQueue": "High_Priority"}
```

Read in your job class:

```apex
Integer hours   = Integer.valueOf(ctx.getParameter('lookbackHours', 24));
Integer size    = Integer.valueOf(ctx.getParameter('batchSize', 200));
Boolean email   = (Boolean) ctx.getParameter('emailResults', false);
String  queue   = (String)  ctx.getParameter('targetQueue', 'Default');
```

`getParameter(key, defaultValue)` returns the default when the key is absent — safe to call even when `ExecutionParameters__c` is blank.

---

## 10. Passing Data Between Steps

Steps share state via `ctx.sharedContext` — a `Map<String, Object>` that is:
- Persisted as JSON to `JobPipelineRun__c.ContextData__c` after every step
- Reloaded for every subsequent step in the same pipeline run

```apex
// Step A writes
ctx.sharedContext.put('recordCount', 1500);
ctx.sharedContext.put('lastRunTimestamp', String.valueOf(System.now()));

// Step B reads (downstream step)
Integer count = (Integer) ctx.getSharedValue('recordCount', 0);
```

**Limits:**
- `ContextData__c` is a LongTextArea with a 131,072 character limit
- For large payloads, store data in a Custom Object and put the record Id in sharedContext:
  ```apex
  ctx.sharedContext.put('summaryRecordId', summaryRecord.Id);
  ```

---

## 11. Monitoring & Troubleshooting

### Monitor from the App

Open the **Job Scheduler** app → use the three tabs:
- **Job Pipeline Runs** — one row per execution, shows Status, StartTime, EndTime
- **Job Step Executions** — related list on a Run; one row per step attempt
- **Job Execution Logs** — INFO and ERROR messages with timestamps

### SOQL Queries

**Recent pipeline runs:**
```apex
SELECT Name, Pipeline__c, Status__c, TriggeredBy__c,
       StartTime__c, EndTime__c
FROM   JobPipelineRun__c
ORDER BY CreatedDate DESC
LIMIT  20;
```

**Step details for a specific run:**
```apex
SELECT StepDeveloperName__c, Status__c, AttemptNumber__c,
       StartTime__c, EndTime__c, RecordsProcessed__c,
       RecordsFailed__c, ErrorMessage__c, ApexClassName__c
FROM   JobStepExecution__c
WHERE  PipelineRun__c = '<PASTE_RUN_ID_HERE>'
ORDER BY StartTime__c ASC;
```

**Execution logs for a run:**
```apex
SELECT LogLevel__c, Message__c, Timestamp__c,
       StepExecution__r.StepDeveloperName__c
FROM   JobExecutionLog__c
WHERE  PipelineRun__c = '<PASTE_RUN_ID_HERE>'
ORDER BY Timestamp__c ASC;
```

**Active async jobs (in-flight steps):**
```apex
SELECT Id, ApexClass.Name, Status, JobType,
       NumberOfErrors, TotalJobItems, JobItemsProcessed
FROM   AsyncApexJob
WHERE  Status IN ('Queued','Processing','Preparing')
AND    ApexClass.Name LIKE '%Job%'
ORDER BY CreatedDate DESC;
```

### Abort a Running Pipeline

```apex
// Step 1 — mark the run as Cancelled (orchestrator no-ops on next event)
update new JobPipelineRun__c(Id = '<RUN_ID>', Status__c = 'Cancelled');

// Step 2 — abort any in-flight async jobs
for (JobStepExecution__c e : [
    SELECT AsyncApexJobId__c FROM JobStepExecution__c
    WHERE PipelineRun__c = '<RUN_ID>' AND Status__c = 'Running'
]) {
    if (String.isNotBlank(e.AsyncApexJobId__c)) {
        System.abortJob(e.AsyncApexJobId__c);
    }
}
```

### Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pipeline stops after first step, status stays `Running` | `JobCompletionTrigger` is inactive or missing | Setup → Apex Triggers → activate `JobCompletionTrigger` |
| `runNow()` returns `null` | Pipeline DeveloperName not found or `IsActive__c = false` | Check the exact DeveloperName in the `JobPipeline__mdt` CMT |
| Step `Status = Running` but no `AsyncApexJobId__c` | `JobDispatcher.dispatch()` threw an exception after inserting the execution record | Query `JobExecutionLog__c` for ERROR entries on that run |
| `No active JobPipeline__mdt found` | Typo in DeveloperName or IsActive unchecked | Verify in Setup → Custom Metadata Types → Job Pipeline → Manage Records |
| `Apex class not found: MyJobClass` | Class name in `ApexClassName__c` is wrong or class not deployed | Check spelling; run `System.debug(Type.forName('MyJobClass'));` in Anonymous Apex |
| `CircularDependencyException` | A dependency chain forms a cycle (A→B→A) | Review `JobDependency__mdt` records; remove the circular edge |
| Pipeline deadlocked — status never `Completed` | A step is Failed with `ContinueOnError` but its dependents also depend on an unreachable path | Query `JobExecutionLog__c` for `Pipeline deadlocked` errors; check dependency config |
| `SOQL row retrieved without querying field` runtime error | A field queried inside the orchestrator was not included in its SOQL | File a bug — should not occur in normal operation |
| Steps running more than once | Retry policy fired, or duplicate Platform Events triggered duplicate orchestrator passes | Check `AttemptNumber__c` on `JobStepExecution__c`; review `JobRetryPolicy__mdt` settings |

---

## 12. Configuration Reference

### `JobPipeline__mdt` fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `DeveloperName` | Text(40) | ✓ | API name — used in `runNow()` and `registerSchedule()` |
| `Label` | Text | ✓ | Human-readable display name |
| `IsActive__c` | Checkbox | ✓ | `false` disables the pipeline without deleting it |
| `CronExpression__c` | Text(255) | | Salesforce cron string; used by `registerSchedule()` |
| `OnStepFailure__c` | Picklist | ✓ | `AbortPipeline` — stop on first failure; `ContinueOnError` — skip failed branches and continue |
| `NotificationEmail__c` | Email | | Alert email address on pipeline failure |
| `MaxPipelineRuntime__c` | Number | | Wall-clock timeout in minutes; orchestrator marks run Failed if exceeded |
| `MaxConcurrentSteps__c` | Number | | Max steps dispatched per orchestrator pass; hard-capped at 50 |

### `JobStep__mdt` fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Pipeline__c` | MetadataRelationship | ✓ | Parent `JobPipeline__mdt` DeveloperName |
| `ApexClassName__c` | Text(255) | ✓ | Exact class name that implements `ISchedulableJob` |
| `ExecutionMode__c` | Picklist | ✓ | `Queueable` or `Batch` |
| `BatchSize__c` | Number | | Records per batch chunk (default 200; Batch mode only) |
| `ExecutionOrder__c` | Number | | Display-order hint; execution order is defined by `JobDependency__mdt` |
| `IsActive__c` | Checkbox | ✓ | `false` skips this step in every run |
| `BranchGroup__c` | Text(255) | | Steps sharing this value are dispatched in parallel |
| `RetryPolicy__c` | MetadataRelationship | | Points to a `JobRetryPolicy__mdt` DeveloperName |
| `ExecutionParameters__c` | LongTextArea | | JSON parameters passed to the job via `ctx.getParameter()` |
| `TimeoutMinutes__c` | Number | | Per-step watchdog timeout |

### `JobDependency__mdt` fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Pipeline__c` | MetadataRelationship | ✓ | Parent pipeline |
| `StepToRun__c` | Text(255) | ✓ | DeveloperName of the step that must **wait** |
| `DependsOnStep__c` | Text(255) | ✓ | DeveloperName of the step that must **complete first** |

### `JobRetryPolicy__mdt` fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `MaxRetries__c` | Number | 3 | Max attempts before permanent failure |
| `RetryDelaySeconds__c` | Number | 60 | Seconds to wait before re-dispatch |
| `RetryOnlyOnExceptions__c` | Checkbox | false | If true, only retry when an exception is thrown (not on data errors) |
| `RetryExceptionTypes__c` | LongTextArea | *(blank = any)* | Comma-separated exception class names to retry on |

### `JobPipelineRun__c` fields (runtime — read-only for Admin)

| Field | Description |
|-------|-------------|
| `Name` | Auto-number: `RUN-0001` |
| `Pipeline__c` | DeveloperName of the pipeline |
| `Status__c` | `Queued` → `Running` → `Completed` / `Failed` / `Cancelled` |
| `TriggeredBy__c` | `Manual`, `Scheduled`, or `Event` |
| `StartTime__c` | When the orchestrator first ran |
| `EndTime__c` | When the run reached a terminal state |
| `ContextData__c` | JSON blob of shared context written by job steps |

### `JobStepExecution__c` fields (runtime — read-only for Admin)

| Field | Description |
|-------|-------------|
| `Name` | Auto-number: `STEP-0001` |
| `PipelineRun__c` | Parent `JobPipelineRun__c` |
| `StepDeveloperName__c` | DeveloperName from `JobStep__mdt` |
| `ApexClassName__c` | Class that ran |
| `Status__c` | `Running` → `Completed` / `Failed` / `Skipped` / `Retrying` |
| `AttemptNumber__c` | 1 for first run; increments on retry |
| `AsyncApexJobId__c` | The `AsyncApexJob.Id` for the running batch/queueable |
| `StartTime__c` / `EndTime__c` | Step execution window |
| `RecordsProcessed__c` / `RecordsFailed__c` | Batch record counts |
| `ErrorMessage__c` / `ErrorStackTrace__c` | Set on failure |

---

## 13. Governor Limit Handling

| Limit | Impact | How the framework handles it |
|-------|--------|------------------------------|
| Queueable chain depth (50) | Long pipelines would hit the limit | `JobCompletionEvent__e` fires in a new top-level transaction — depth resets to 0 after every step |
| `enqueueJob` calls per transaction (50) | Parallel step bursts | `MaxConcurrentSteps__c` caps dispatch per orchestrator pass; hard limit enforced at 50 |
| Batch concurrency (5 simultaneous) | Too many batch steps in parallel | `JobDispatcher` checks live `AsyncApexJob` count before submitting; excess steps wait for the next orchestrator pass |
| SOQL queries per transaction (100) | Complex pipelines | CMT queries are cached by Salesforce; orchestrator uses ≤ 3 SOQL per pass |
| Heap size (6 MB sync / 12 MB async) | Large shared context | `ContextData__c` is SOQL-loaded per step; context not held in memory across transactions |
| DML rows (10,000) | Large batch executes | Each batch chunk is a separate transaction; DML limits apply per chunk, not per pipeline |
| Platform Event publish per transaction (150) | Many parallel steps completing at once | One event per step; well within limits for normal pipeline sizes |
