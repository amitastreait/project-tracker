/**
 * JobDependencyResolver
 *
 * Pure stateless utility that implements DAG resolution for the job scheduler.
 * Has no SOQL, no DML — all inputs are passed in so this class is fully unit-testable
 * without any org data.
 *
 * Responsibilities:
 *   1. Build an in-memory adjacency list from JobStep__mdt + JobDependency__mdt records.
 *   2. Detect circular dependencies (throws CircularDependencyException).
 *   3. Return the list of step DeveloperNames that are "ready" to execute:
 *      — all of their upstream dependency steps are in 'Completed' status
 *      — the step itself has not yet started (null status in the map)
 */
public class JobDependencyResolver {

    public class CircularDependencyException extends Exception {}

    /**
     * Returns step DeveloperNames that are eligible for dispatch in the current orchestrator pass.
     *
     * @param allSteps        All active JobStep__mdt records for the pipeline.
     * @param allDependencies All JobDependency__mdt edges for the pipeline.
     * @param stepStatusByName  Map of step DeveloperName → latest JobStepExecution__c.Status__c.
     *                          A null value means the step has never been dispatched (ready candidate).
     * @return                List of step DeveloperNames that can be dispatched now.
     */
    public static List<String> getReadySteps(
        List<JobStep__mdt> allSteps,
        List<JobDependency__mdt> allDependencies,
        Map<String, String> stepStatusByName
    ) {
        // Build dependency map: step DeveloperName → set of upstream step names it waits on
        Map<String, Set<String>> dependsOn = buildDependencyMap(allSteps, allDependencies);

        detectCycles(dependsOn);

        List<String> readySteps = new List<String>();

        for (String stepName : dependsOn.keySet()) {
            String currentStatus = stepStatusByName.get(stepName);

            // Only steps that have never been dispatched are candidates
            if (currentStatus != null) {
                continue;
            }

            // All upstream dependencies must be Completed
            if (allDependenciesCompleted(dependsOn.get(stepName), stepStatusByName)) {
                readySteps.add(stepName);
            }
        }

        return readySteps;
    }

    /**
     * Returns step DeveloperNames whose dependencies will never be satisfied because
     * at least one upstream dependency has Failed. Used by the orchestrator to mark
     * unreachable steps as Skipped when OnStepFailure = ContinueOnError.
     */
    public static List<String> getUnreachableSteps(
        List<JobStep__mdt> allSteps,
        List<JobDependency__mdt> allDependencies,
        Map<String, String> stepStatusByName
    ) {
        Map<String, Set<String>> dependsOn = buildDependencyMap(allSteps, allDependencies);
        List<String> unreachable = new List<String>();

        for (String stepName : dependsOn.keySet()) {
            String currentStatus = stepStatusByName.get(stepName);
            if (currentStatus != null) {
                continue; // Already handled
            }

            for (String depName : dependsOn.get(stepName)) {
                String depStatus = stepStatusByName.get(depName);
                if (depStatus == 'Failed' || depStatus == 'Skipped') {
                    unreachable.add(stepName);
                    break;
                }
            }
        }

        return unreachable;
    }

    // ─── Private helpers ────────────────────────────────────────────────────────

    private static Map<String, Set<String>> buildDependencyMap(
        List<JobStep__mdt> allSteps,
        List<JobDependency__mdt> allDependencies
    ) {
        Map<String, Set<String>> dependsOn = new Map<String, Set<String>>();

        for (JobStep__mdt step : allSteps) {
            if (step.IsActive__c) {
                dependsOn.put(step.DeveloperName, new Set<String>());
            }
        }

        for (JobDependency__mdt dep : allDependencies) {
            if (dependsOn.containsKey(dep.StepToRun__c)) {
                dependsOn.get(dep.StepToRun__c).add(dep.DependsOnStep__c);
            }
        }

        return dependsOn;
    }

    private static Boolean allDependenciesCompleted(
        Set<String> upstreamSteps,
        Map<String, String> stepStatusByName
    ) {
        for (String depName : upstreamSteps) {
            if (stepStatusByName.get(depName) != 'Completed') {
                return false;
            }
        }
        return true;
    }

    /**
     * DFS cycle detection. Throws CircularDependencyException if a cycle is found.
     * An inStack set tracks nodes in the current DFS path to distinguish back-edges
     * (cycles) from cross-edges (valid DAG paths to already-visited nodes).
     */
    private static void detectCycles(Map<String, Set<String>> dependsOn) {
        Set<String> visited = new Set<String>();
        Set<String> inStack = new Set<String>();

        for (String node : dependsOn.keySet()) {
            if (!visited.contains(node)) {
                if (hasCycle(node, dependsOn, visited, inStack)) {
                    throw new CircularDependencyException(
                        'Circular dependency detected in pipeline configuration. ' +
                        'Check JobDependency__mdt records — no step should (directly or ' +
                        'indirectly) depend on itself.'
                    );
                }
            }
        }
    }

    private static Boolean hasCycle(
        String node,
        Map<String, Set<String>> dependsOn,
        Set<String> visited,
        Set<String> inStack
    ) {
        visited.add(node);
        inStack.add(node);

        if (dependsOn.containsKey(node)) {
            for (String upstream : dependsOn.get(node)) {
                if (!visited.contains(upstream)) {
                    if (hasCycle(upstream, dependsOn, visited, inStack)) {
                        return true;
                    }
                } else if (inStack.contains(upstream)) {
                    return true; // Back-edge → cycle found
                }
            }
        }

        inStack.remove(node);
        return false;
    }
}
