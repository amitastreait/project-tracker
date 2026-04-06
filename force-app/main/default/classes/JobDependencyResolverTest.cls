/**
 * JobDependencyResolverTest
 *
 * Covers all DAG resolution scenarios.
 * No SOQL or DML — all inputs are built in-memory so tests run fast and are
 * completely isolated from org data.
 */
@IsTest
private class JobDependencyResolverTest {

    // ── getReadySteps ────────────────────────────────────────────────────────

    @IsTest
    static void testLinearChain_firstStepReadyWhenNothingStarted() {
        // Graph: A → B → C
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('C', 'B')
        };

        List<String> ready = JobDependencyResolver.getReadySteps(
            steps, deps, new Map<String, String>()
        );

        System.assertEquals(1, ready.size(), 'Only A should be ready');
        System.assertEquals('A', ready[0]);
    }

    @IsTest
    static void testLinearChain_secondStepReadyAfterFirstCompletes() {
        // A completed → B should be ready, C should not
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('C', 'B')
        };
        Map<String, String> status = new Map<String, String>{ 'A' => 'Completed' };

        List<String> ready = JobDependencyResolver.getReadySteps(steps, deps, status);

        System.assertEquals(1, ready.size());
        System.assertEquals('B', ready[0]);
        System.assert(!ready.contains('C'), 'C must wait for B');
    }

    @IsTest
    static void testParallelBranch_bothChildrenReadyWhenParentCompletes() {
        // Graph: A → (B ∥ C)
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('C', 'A')
        };
        Map<String, String> status = new Map<String, String>{ 'A' => 'Completed' };

        List<String> ready = JobDependencyResolver.getReadySteps(steps, deps, status);

        System.assertEquals(2, ready.size(), 'Both B and C should be ready');
        System.assert(ready.contains('B'));
        System.assert(ready.contains('C'));
    }

    @IsTest
    static void testAndJoin_notReadyUntilAllDepsComplete() {
        // Graph: (A, B) → C  — AND-join
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('C', 'A'), dep('C', 'B')
        };
        // Only A is done — B still running
        Map<String, String> status = new Map<String, String>{
            'A' => 'Completed', 'B' => 'Running'
        };

        List<String> ready = JobDependencyResolver.getReadySteps(steps, deps, status);

        System.assert(!ready.contains('C'), 'C must wait for B to complete too');
    }

    @IsTest
    static void testAndJoin_readyWhenAllDepsComplete() {
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('C', 'A'), dep('C', 'B')
        };
        Map<String, String> status = new Map<String, String>{
            'A' => 'Completed', 'B' => 'Completed'
        };

        List<String> ready = JobDependencyResolver.getReadySteps(steps, deps, status);

        System.assertEquals(1, ready.size());
        System.assertEquals('C', ready[0]);
    }

    @IsTest
    static void testAlreadyStartedStepsAreSkipped() {
        // A is running — should not appear in ready list
        List<JobStep__mdt> steps = steps('A', 'B');
        Map<String, String> status = new Map<String, String>{ 'A' => 'Running' };

        List<String> ready = JobDependencyResolver.getReadySteps(
            steps, new List<JobDependency__mdt>(), status
        );

        System.assert(!ready.contains('A'), 'Running step must not be re-dispatched');
    }

    @IsTest
    static void testNoDependencies_allStepsReadyOnFirstPass() {
        // Three independent steps with no edges
        List<JobStep__mdt> steps = new List<JobStep__mdt>{
            new JobStep__mdt(DeveloperName='X', IsActive__c=true),
            new JobStep__mdt(DeveloperName='Y', IsActive__c=true),
            new JobStep__mdt(DeveloperName='Z', IsActive__c=true)
        };

        List<String> ready = JobDependencyResolver.getReadySteps(
            steps, new List<JobDependency__mdt>(), new Map<String, String>()
        );

        System.assertEquals(3, ready.size(), 'All three should be immediately ready');
    }

    // ── Cycle detection ──────────────────────────────────────────────────────

    @IsTest
    static void testDirectCycle_throwsCircularDependencyException() {
        // A → B → A
        List<JobStep__mdt> steps = steps('A', 'B');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('A', 'B')
        };

        try {
            JobDependencyResolver.getReadySteps(steps, deps, new Map<String, String>());
            System.assert(false, 'Expected CircularDependencyException was not thrown');
        } catch (JobDependencyResolver.CircularDependencyException ex) {
            System.assert(
                ex.getMessage().containsIgnoreCase('Circular dependency'),
                'Exception message should mention circular dependency'
            );
        }
    }

    @IsTest
    static void testIndirectCycle_throwsCircularDependencyException() {
        // A → B → C → A
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('C', 'B'), dep('A', 'C')
        };

        try {
            JobDependencyResolver.getReadySteps(steps, deps, new Map<String, String>());
            System.assert(false, 'Expected CircularDependencyException');
        } catch (JobDependencyResolver.CircularDependencyException ex) {
            System.assert(true, 'Correct exception thrown');
        }
    }

    // ── getUnreachableSteps ──────────────────────────────────────────────────

    @IsTest
    static void testUnreachableSteps_directDependencyFailed() {
        // A failed → B is unreachable
        List<JobStep__mdt> steps = steps('A', 'B', 'C');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{
            dep('B', 'A'), dep('C', 'B')
        };
        Map<String, String> status = new Map<String, String>{ 'A' => 'Failed' };

        List<String> unreachable = JobDependencyResolver.getUnreachableSteps(
            steps, deps, status
        );

        System.assertEquals(1, unreachable.size());
        System.assertEquals('B', unreachable[0]);
    }

    @IsTest
    static void testNoUnreachableSteps_whenNothingFailed() {
        List<JobStep__mdt> steps = steps('A', 'B');
        List<JobDependency__mdt> deps = new List<JobDependency__mdt>{ dep('B', 'A') };
        Map<String, String> status = new Map<String, String>{ 'A' => 'Completed' };

        List<String> unreachable = JobDependencyResolver.getUnreachableSteps(
            steps, deps, status
        );

        System.assertEquals(0, unreachable.size());
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static List<JobStep__mdt> steps(String n1, String n2) {
        return steps(new List<String>{ n1, n2 });
    }

    private static List<JobStep__mdt> steps(String n1, String n2, String n3) {
        return steps(new List<String>{ n1, n2, n3 });
    }

    private static List<JobStep__mdt> steps(List<String> names) {
        List<JobStep__mdt> result = new List<JobStep__mdt>();
        for (String n : names) {
            result.add(new JobStep__mdt(DeveloperName = n, IsActive__c = true));
        }
        return result;
    }

    private static JobDependency__mdt dep(String stepToRun, String dependsOn) {
        return new JobDependency__mdt(
            StepToRun__c     = stepToRun,
            DependsOnStep__c = dependsOn
        );
    }
}
